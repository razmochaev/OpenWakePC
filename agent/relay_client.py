"""
Persistent E2EE WebSocket Relay Client for the Desktop Agent.

Speaks the official Wake PC Relay v1 WebSocket protocol (`/agent/<deviceId>`):
1. Receives `{"t": "challenge", "nonce": "..."}`
2. Replies `{"t": "claim", "claim": Base64(HMAC(key, "room-claim")), "proof": Base64(HMAC(key, nonce))}`
3. Receives `{"t": "ready"}`
4. Handles `{"t": "cmd", "rid": id, "env": envelope}` -> `{"t": "resp", "rid": id, "env": resp_envelope}`
5. Sends push notifications `{"t": "notify", "event": "idle", "hours": N}` and heartbeats `{"t": "ping"}`.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Awaitable, Callable

import aiohttp

from common.crypto import (
    RelayCryptoError,
    compute_claim_proof,
    compute_room_claim,
    decode_command_payload,
    open_envelope,
    seal_envelope,
)

from .config import AgentConfig

logger = logging.getLogger("wakepc.agent.relay_client")

CommandHandler = Callable[[str, dict[str, str]], Awaitable[dict[str, Any]]]


class AgentRelayClient:
    """Maintains an auto-reconnecting E2EE WebSocket tunnel to a self-hosted relay."""

    def __init__(
        self,
        config: AgentConfig,
        command_handler: CommandHandler,
    ) -> None:
        self.config = config
        self.command_handler = command_handler
        self._task: asyncio.Task[None] | None = None
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._stop_event = asyncio.Event()
        self.connected_event = asyncio.Event()

    async def resolve_relay_url(self, session: aiohttp.ClientSession) -> str:
        if self.config.relay_url:
            return self.config.relay_url.rstrip("/")
        if self.config.relay_discovery_url:
            async with session.get(
                self.config.relay_discovery_url,
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                resp.raise_for_status()
                payload = await resp.json()
                url = str(payload.get("url") or payload.get("relay_url") or "").rstrip("/")
                if url:
                    return url
        return ""

    def start(self) -> None:
        if not self.config.relay_url and not self.config.relay_discovery_url:
            logger.info("No relay_url configured; running in LAN-only mode")
            return
        self._stop_event.clear()
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._run_loop())

    async def stop(self) -> None:
        self._stop_event.set()
        if self._ws is not None and not self._ws.closed:
            await self._ws.close()
        if self._task is not None and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None
        self.connected_event.clear()

    async def send_idle_event(self, idle_hours: int) -> None:
        """Notify relay that this PC has been idle for `idle_hours` (triggers PC_IDLE push)."""
        if self._ws is not None and not self._ws.closed:
            await self._ws.send_json({"t": "notify", "event": "idle", "hours": idle_hours})

    async def _run_loop(self) -> None:
        backoff = 1.0
        async with aiohttp.ClientSession() as session:
            while not self._stop_event.is_set():
                try:
                    base_url = await self.resolve_relay_url(session)
                    if not base_url:
                        await asyncio.sleep(5.0)
                        continue
                    ws_url = _http_to_ws_url(base_url) + f"/agent/{self.config.device_id}"
                    claim = compute_room_claim(self.config.token, self.config.device_id)

                    async with session.ws_connect(ws_url, heartbeat=30.0) as ws:
                        self._ws = ws

                        # 1. Wait for challenge frame
                        challenge = await ws.receive_json(timeout=10.0)
                        if challenge.get("t") != "challenge" or not isinstance(challenge.get("nonce"), str):
                            raise ConnectionRefusedError(f"Expected challenge frame, got: {challenge}")

                        # 2. Send claim + HMAC proof over nonce
                        proof = compute_claim_proof(self.config.token, self.config.device_id, challenge["nonce"])
                        await ws.send_json({"t": "claim", "claim": claim, "proof": proof})

                        # 3. Wait for ready frame
                        ready = await ws.receive_json(timeout=10.0)
                        if ready.get("t") != "ready":
                            raise ConnectionRefusedError(f"Expected ready frame, got: {ready}")

                        backoff = 1.0
                        self.connected_event.set()
                        logger.info("Relay: online (%s as %s)", base_url, self.config.device_id)

                        async for msg in ws:
                            if msg.type == aiohttp.WSMsgType.TEXT:
                                await self._handle_ws_message(ws, msg.data)
                            elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
                                break
                except asyncio.CancelledError:
                    break
                except Exception as exc:
                    logger.warning("Relay tunnel disconnected (%s); retrying in %.1fs", exc, backoff)
                finally:
                    self.connected_event.clear()
                    self._ws = None

                if not self._stop_event.is_set():
                    await asyncio.sleep(backoff)
                    backoff = min(backoff * 2.0, 30.0)

    async def _handle_ws_message(
        self,
        ws: aiohttp.ClientWebSocketResponse,
        raw_data: str,
    ) -> None:
        try:
            frame = json.loads(raw_data)
        except Exception:
            return
        msg_type = frame.get("t") or frame.get("type")
        if msg_type not in {"cmd", "request"}:
            return

        req_id = str(frame.get("rid") or frame.get("id") or "")
        envelope = frame.get("env") if "env" in frame else frame.get("envelope")
        try:
            plaintext = open_envelope(envelope, self.config.token, self.config.device_id)
            path, query = decode_command_payload(plaintext)
            if ".." in path or "//" in path:
                result: dict[str, Any] = {"success": False, "message": "bad_path"}
            else:
                result = await self.command_handler(path, query)
        except RelayCryptoError as exc:
            result = {"success": False, "message": f"E2EE error: {exc}"}
        except Exception as exc:
            logger.exception("Relay command dispatch error")
            result = {"success": False, "message": str(exc)}

        reply_bytes = json.dumps(result, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        resp_envelope = seal_envelope(
            reply_bytes,
            self.config.token,
            self.config.device_id,
            envelope_id=req_id or None,
        )
        await ws.send_json({"t": "resp", "rid": req_id, "env": resp_envelope})


def _http_to_ws_url(url: str) -> str:
    if url.startswith("https://"):
        return "wss://" + url[len("https://") :]
    if url.startswith("http://"):
        return "ws://" + url[len("http://") :]
    return url
