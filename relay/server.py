"""
Zero-knowledge E2EE Relay HTTP + WebSocket server.

Endpoints:
- GET  /health                   -> liveness + connected agent count
- GET  /relay.json               -> {"relay_url": "<public_url>"} (discovery compatible with iOS client)
- WS   /ws/agent/{device_id}     -> persistent tunnel for Desktop Agent (authenticated via HMAC room-claim)
- POST /send/{device_id}?timeout -> forwards 5-field E2EE envelope to agent and awaits encrypted response
- POST /push/{device_id}         -> registers/unregisters APNs push notifications with room-claim proof
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import re
import secrets
from dataclasses import dataclass, field
from typing import Any

from aiohttp import WSMsgType, web

from common.crypto import validate_envelope_structure, verify_room_claim

from .config import RelayConfig
from .push import LoggingPushNotifier, PushNotifier, PushRegistry, PushSubscription

logger = logging.getLogger("wakepc.relay")

DEVICE_ID_REGEX = re.compile(r"^[A-Za-z0-9_.:-]{4,128}$")
HEX_TOKEN_REGEX = re.compile(r"^[0-9a-fA-F]{16,256}$")


def _is_valid_claim_format(claim: Any) -> bool:
    """Ensure claim is a valid Base64-encoded 32-byte HMAC-SHA256 digest."""
    if not isinstance(claim, str) or not claim:
        return False
    try:
        decoded = base64.b64decode(claim, validate=True)
    except Exception:
        return False
    return len(decoded) == 32


RELAY_APP_KEY = web.AppKey("relay", "RelayServer")


@dataclass
class AgentSession:
    """Active WebSocket tunnel for a single PC agent."""

    device_id: str
    claim: str
    ws: web.WebSocketResponse
    wire_protocol: str = "v1-official"  # "v1-official" (/agent/{id}) | "legacy" (/ws/agent/{id})
    pending: dict[str, asyncio.Future[dict[str, Any]]] = field(default_factory=dict)


class RelayServer:
    """Stateful coordinator for connected agent rooms and pending E2EE requests."""

    def __init__(
        self,
        config: RelayConfig | None = None,
        push_notifier: PushNotifier | None = None,
    ) -> None:
        self.config = config or RelayConfig()
        self.push_registry = PushRegistry(self.config.push_storage_path)
        self.push_notifier: PushNotifier = push_notifier or LoggingPushNotifier()
        self.sessions: dict[str, AgentSession] = {}

    def build_app(self) -> web.Application:
        """Create configured aiohttp web.Application."""
        app = web.Application(client_max_size=self.config.max_body_bytes)
        app[RELAY_APP_KEY] = self
        app.router.add_get("/health", self.handle_health)
        app.router.add_get("/relay.json", self.handle_relay_discovery)
        # Official protocol route used by macOS & Windows Wake PC Agents
        app.router.add_get("/agent/{device_id}", self.handle_official_agent_ws)
        # Backward-compatible legacy route
        app.router.add_get("/ws/agent/{device_id}", self.handle_agent_ws)
        app.router.add_post("/send/{device_id}", self.handle_send)
        app.router.add_post("/push/{device_id}", self.handle_push_register)
        app.on_shutdown.append(self._on_shutdown)
        return app

    async def _on_shutdown(self, _app: web.Application) -> None:
        for session in list(self.sessions.values()):
            for fut in session.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionResetError("Relay shutting down"))
            await session.ws.close(code=1001, message=b"Server shutdown")
        self.sessions.clear()

    async def handle_health(self, _request: web.Request) -> web.Response:
        return web.json_response(
            {
                "status": "ok",
                "connected_agents": len(self.sessions),
            }
        )

    async def handle_relay_discovery(self, request: web.Request) -> web.Response:
        public_url = self.config.public_url
        if not public_url:
            scheme = request.headers.get("X-Forwarded-Proto", request.scheme)
            public_url = f"{scheme}://{request.host}"
        return web.json_response({"relay_url": public_url.rstrip("/")})

    async def handle_official_agent_ws(self, request: web.Request) -> web.StreamResponse:
        """
        Official Wake PC Agent WebSocket tunnel (`/agent/{device_id}`):
        1. Server sends `{"t": "challenge", "nonce": "<hex>"}`
        2. Agent replies `{"t": "claim", "claim": "<b64 HMAC>", "proof": "<b64 HMAC>"}`
        3. Server verifies room claim and replies `{"t": "ready"}`
        4. Commands use `{"t": "cmd", "rid": id, "env": envelope}` <-> `{"t": "resp", "rid": id, "env": envelope}`
        5. Heartbeat uses `{"t": "ping"}` <-> `{"t": "pong"}`; events use `{"t": "notify", "event": ..., "hours": ...}`
        """
        device_id = request.match_info["device_id"]
        if not DEVICE_ID_REGEX.match(device_id):
            return web.json_response({"success": False, "error": "invalid_device_id"}, status=400)

        ws = web.WebSocketResponse(
            heartbeat=self.config.heartbeat_interval_sec,
            max_msg_size=self.config.max_body_bytes,
        )
        await ws.prepare(request)

        nonce_raw = secrets.token_bytes(16)
        nonce = base64.b64encode(nonce_raw).decode("ascii")
        await ws.send_json({"t": "challenge", "nonce": nonce})

        try:
            reply_msg = await asyncio.wait_for(ws.receive(), timeout=10.0)
        except asyncio.TimeoutError:
            await ws.close(code=4001, message=b"Challenge timeout")
            return ws

        if reply_msg.type != WSMsgType.TEXT:
            await ws.close(code=4002, message=b"Expected claim frame")
            return ws

        try:
            claim_frame = json.loads(reply_msg.data)
        except Exception:
            await ws.close(code=4002, message=b"Malformed claim JSON")
            return ws

        if claim_frame.get("t") != "claim":
            await ws.close(code=4002, message=b"Expected claim message")
            return ws

        claim = claim_frame.get("claim", "")
        proof = claim_frame.get("proof", "")
        if not _is_valid_claim_format(claim) or not _is_valid_claim_format(proof):
            await ws.close(code=4003, message=b"Invalid claim or proof")
            return ws

        claim_raw = base64.b64decode(claim)
        expected_proof = base64.b64encode(hmac.new(claim_raw, nonce_raw, hashlib.sha256).digest()).decode("ascii")
        if not verify_room_claim(expected_proof, proof):
            await ws.close(code=4003, message=b"bad_proof")
            return ws

        existing = self.sessions.get(device_id)
        if existing is not None and not verify_room_claim(existing.claim, claim):
            await ws.close(code=4003, message=b"Room claim mismatch")
            return ws

        if existing is not None:
            for fut in existing.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionResetError("Replaced by new agent connection"))
            await existing.ws.close(code=1000, message=b"Replaced by new connection")

        session = AgentSession(device_id=device_id, claim=claim, ws=ws, wire_protocol="v1-official")
        self.sessions[device_id] = session
        await ws.send_json({"t": "ready"})
        logger.info("Agent connected (official protocol): device_id=%s", device_id)
        await self._dispatch_push_event(device_id, "pc_online", {})

        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    await self._handle_agent_message(session, msg.data)
                elif msg.type == WSMsgType.ERROR:
                    logger.warning("Agent WS error device_id=%s: %s", device_id, ws.exception())
        finally:
            if self.sessions.get(device_id) is session:
                self.sessions.pop(device_id, None)
                for fut in session.pending.values():
                    if not fut.done():
                        fut.set_exception(ConnectionResetError("Agent disconnected"))
                logger.info("Agent disconnected: device_id=%s", device_id)
                await self._dispatch_push_event(device_id, "pc_offline", {})

        return ws

    async def handle_agent_ws(self, request: web.Request) -> web.StreamResponse:
        device_id = request.match_info["device_id"]
        if not DEVICE_ID_REGEX.match(device_id):
            return web.json_response({"success": False, "error": "invalid_device_id"}, status=400)

        ws = web.WebSocketResponse(
            heartbeat=self.config.heartbeat_interval_sec,
            max_msg_size=self.config.max_body_bytes,
        )
        await ws.prepare(request)

        # Authenticate via X-WakePC-Claim header or first JSON {"type": "auth", "claim": "..."}
        claim = request.headers.get("X-WakePC-Claim", "")
        if not claim:
            try:
                first_msg = await asyncio.wait_for(ws.receive(), timeout=10.0)
            except asyncio.TimeoutError:
                await ws.close(code=4001, message=b"Auth timeout")
                return ws

            if first_msg.type != WSMsgType.TEXT:
                await ws.close(code=4002, message=b"Expected auth frame")
                return ws

            try:
                auth_payload = json.loads(first_msg.data)
            except Exception:
                await ws.close(code=4002, message=b"Malformed auth JSON")
                return ws

            if auth_payload.get("type") != "auth":
                await ws.close(code=4002, message=b"Expected auth message")
                return ws
            claim = str(auth_payload.get("claim", ""))

        if not _is_valid_claim_format(claim):
            await ws.send_json({"type": "auth_error", "error": "invalid_claim"})
            await ws.close(code=4003, message=b"Invalid room claim")
            return ws

        # If a previous active session exists with a different claim, reject hijacking
        existing = self.sessions.get(device_id)
        if existing is not None and not verify_room_claim(existing.claim, claim):
            await ws.send_json({"type": "auth_error", "error": "claim_mismatch"})
            await ws.close(code=4003, message=b"Room claim mismatch")
            return ws

        if existing is not None:
            # Replace stale connection from the same legitimate agent
            for fut in existing.pending.values():
                if not fut.done():
                    fut.set_exception(ConnectionResetError("Replaced by new agent connection"))
            await existing.ws.close(code=1000, message=b"Replaced by new connection")

        session = AgentSession(device_id=device_id, claim=claim, ws=ws, wire_protocol="legacy")
        self.sessions[device_id] = session
        await ws.send_json({"type": "auth_ok", "device_id": device_id})
        logger.info("Agent connected: device_id=%s", device_id)
        await self._dispatch_push_event(device_id, "pc_online", {})

        try:
            async for msg in ws:
                if msg.type == WSMsgType.TEXT:
                    await self._handle_agent_message(session, msg.data)
                elif msg.type == WSMsgType.ERROR:
                    logger.warning("Agent WS error device_id=%s: %s", device_id, ws.exception())
        finally:
            if self.sessions.get(device_id) is session:
                self.sessions.pop(device_id, None)
                for fut in session.pending.values():
                    if not fut.done():
                        fut.set_exception(ConnectionResetError("Agent disconnected"))
                logger.info("Agent disconnected: device_id=%s", device_id)
                await self._dispatch_push_event(device_id, "pc_offline", {})

        return ws

    async def _handle_agent_message(self, session: AgentSession, raw_text: str) -> None:
        try:
            data = json.loads(raw_text)
        except Exception:
            logger.debug("Ignoring malformed JSON from agent %s", session.device_id)
            return

        # Official v1 protocol frames use key "t"; legacy uses key "type"
        msg_type = data.get("t") or data.get("type")
        if msg_type in {"resp", "response"}:
            req_id = str(data.get("rid") or data.get("id") or "")
            envelope = data.get("env") if "env" in data else data.get("envelope")
            valid, _ = validate_envelope_structure(envelope)
            fut = session.pending.pop(req_id, None)
            if fut is not None and not fut.done():
                if valid:
                    fut.set_result(envelope)
                else:
                    fut.set_exception(ValueError("Agent returned malformed E2EE envelope"))
        elif msg_type in {"notify", "event"}:
            raw_event = str(data.get("event", ""))
            event_map = {"idle": "pc_idle", "online": "pc_online", "offline": "pc_offline"}
            event_name = event_map.get(raw_event, raw_event)
            if event_name in {"pc_idle", "pc_online", "pc_offline"}:
                extra = {k: v for k, v in data.items() if k not in {"t", "type", "event"}}
                if "hours" in extra and "idle_hours" not in extra:
                    extra["idle_hours"] = extra["hours"]
                await self._dispatch_push_event(session.device_id, event_name, extra)
        elif msg_type == "ping":
            if session.wire_protocol == "v1-official":
                await session.ws.send_json({"t": "pong"})
            else:
                await session.ws.send_json({"type": "pong"})

    async def handle_send(self, request: web.Request) -> web.Response:
        device_id = request.match_info["device_id"]
        if not DEVICE_ID_REGEX.match(device_id):
            return web.json_response({"success": False, "error": "invalid_device_id"}, status=400)

        try:
            envelope = await request.json()
        except Exception:
            return web.json_response({"success": False, "error": "invalid_json"}, status=400)

        valid, reason = validate_envelope_structure(envelope)
        if not valid:
            return web.json_response(
                {"success": False, "error": "invalid_envelope", "detail": reason},
                status=400,
            )

        session = self.sessions.get(device_id)
        if session is None or session.ws.closed:
            return web.json_response(
                {"success": False, "error": "agent_offline"},
                status=502,
            )

        timeout_raw = request.query.get("timeout")
        timeout = self.config.default_timeout_sec
        if timeout_raw is not None:
            try:
                parsed = float(timeout_raw)
                timeout = max(1.0, min(parsed, self.config.max_timeout_sec))
            except ValueError:
                return web.json_response({"success": False, "error": "invalid_timeout"}, status=400)

        req_id = envelope["id"]
        loop = asyncio.get_running_loop()
        fut: asyncio.Future[dict[str, Any]] = loop.create_future()
        session.pending[req_id] = fut

        try:
            if session.wire_protocol == "v1-official":
                await session.ws.send_json({"t": "cmd", "rid": req_id, "env": envelope})
            else:
                await session.ws.send_json({"type": "request", "id": req_id, "envelope": envelope})
            response_envelope = await asyncio.wait_for(fut, timeout=timeout)
            return web.json_response(response_envelope, status=200)
        except asyncio.TimeoutError:
            session.pending.pop(req_id, None)
            return web.json_response({"success": False, "error": "timeout"}, status=504)
        except ConnectionResetError:
            session.pending.pop(req_id, None)
            return web.json_response({"success": False, "error": "agent_offline"}, status=502)
        except ValueError as exc:
            session.pending.pop(req_id, None)
            return web.json_response({"success": False, "error": str(exc)}, status=502)

    async def handle_push_register(self, request: web.Request) -> web.Response:
        device_id = request.match_info["device_id"]
        if not DEVICE_ID_REGEX.match(device_id):
            return web.json_response({"success": False, "error": "invalid_device_id"}, status=400)

        try:
            body = await request.json()
        except Exception:
            return web.json_response({"success": False, "error": "invalid_json"}, status=400)

        if not isinstance(body, dict):
            return web.json_response({"success": False, "error": "invalid_body"}, status=400)

        claim = body.get("claim")
        token = body.get("token")
        name = body.get("name", "")
        env = body.get("env", "production")
        enable = body.get("enable", True)
        caps = body.get("caps", [])

        if not _is_valid_claim_format(claim):
            return web.json_response({"success": False, "error": "invalid_claim"}, status=403)
        if not isinstance(token, str) or not HEX_TOKEN_REGEX.match(token):
            return web.json_response({"success": False, "error": "invalid_apns_token"}, status=400)
        if env not in {"production", "development"}:
            return web.json_response({"success": False, "error": "invalid_env"}, status=400)
        if not isinstance(enable, bool):
            return web.json_response({"success": False, "error": "invalid_enable"}, status=400)
        if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
            return web.json_response({"success": False, "error": "invalid_caps"}, status=400)

        # Verify claim against live agent session or previously registered room claim
        session = self.sessions.get(device_id)
        expected_claim = session.claim if session else self.push_registry.get_known_claim(device_id)
        if expected_claim is not None and not verify_room_claim(expected_claim, claim):
            return web.json_response({"success": False, "error": "claim_mismatch"}, status=403)

        sub = PushSubscription(
            device_id=device_id,
            claim=claim,
            token=token.lower(),
            name=str(name)[:128],
            env=env,
            enable=enable,
            caps=caps[:32],
        )
        self.push_registry.register(sub)
        return web.json_response({"success": True, "enabled": enable})

    async def _dispatch_push_event(
        self,
        device_id: str,
        event: str,
        payload: dict[str, Any],
    ) -> None:
        subs = self.push_registry.get_for_device(device_id)
        for sub in subs:
            try:
                await self.push_notifier.notify(sub, event, payload)
            except Exception as exc:
                logger.warning("Push notification failed for %s: %s", device_id, exc)


def create_relay_app(
    config: RelayConfig | None = None,
    push_notifier: PushNotifier | None = None,
) -> web.Application:
    """Factory helper returning a configured aiohttp Application."""
    server = RelayServer(config=config, push_notifier=push_notifier)
    return server.build_app()
