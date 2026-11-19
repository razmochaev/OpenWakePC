"""End-to-end integration test: Simulated iOS Client <-> Self-hosted E2EE Relay <-> Desktop Agent."""

from __future__ import annotations

import asyncio
import base64
import json
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from agent.backends import MockSystemBackend
from agent.config import AgentConfig
from agent.server import AGENT_APP_KEY, create_agent_app
from common.crypto import (
    compute_room_claim,
    encode_command_payload,
    open_envelope,
    seal_envelope,
)
from relay.config import RelayConfig
from relay.push import LoggingPushNotifier
from relay.server import create_relay_app


@pytest.mark.asyncio
async def test_full_e2ee_relay_to_agent_flow(tmp_path: Path) -> None:
    notifier = LoggingPushNotifier()
    relay_app = create_relay_app(RelayConfig(), push_notifier=notifier)

    async with TestServer(relay_app) as relay_server, TestClient(relay_server) as relay_client:
        relay_base_url = str(relay_server.make_url("")).rstrip("/")

        agent_cfg = AgentConfig(
            name="StudioMac",
            device_id="studio-mac-42",
            device_type="mac",
            token="E2EE_SharedToken_2026",
            mac="11:22:33:44:55:66",
            ip="192.168.0.10",
            broadcast="192.168.0.255",
            relay_url=relay_base_url,
            downloads_dir=str(tmp_path / "dl"),
            enable_bonjour=False,
        )
        backend = MockSystemBackend(screenshot_bytes=b"S" * 80000)
        agent_app = create_agent_app(agent_cfg, backend=backend)

        # Register push notification for presence & idle alerts
        claim = compute_room_claim(agent_cfg.token, agent_cfg.device_id)
        reg = await relay_client.post(
            f"/push/{agent_cfg.device_id}",
            json={
                "claim": claim,
                "token": "deadbeef" * 8,
                "name": agent_cfg.name,
                "env": "production",
                "enable": True,
                "caps": ["presence", "idle"],
            },
        )
        assert reg.status == 200

        async with TestServer(agent_app):
            agent_srv = agent_app[AGENT_APP_KEY]
            await asyncio.wait_for(agent_srv.relay_client.connected_event.wait(), timeout=5.0)

            async def send_via_relay(path: str, query: dict[str, str] | None = None) -> dict:
                plain = encode_command_payload(path, query)
                env = seal_envelope(plain, agent_cfg.token, agent_cfg.device_id)
                resp = await relay_client.post(f"/send/{agent_cfg.device_id}?timeout=10", json=env)
                assert resp.status == 200
                resp_env = await resp.json()
                return json.loads(open_envelope(resp_env, agent_cfg.token, agent_cfg.device_id).decode())

            # 1. Status over E2EE relay
            st = await send_via_relay("/status")
            assert st["success"] is True
            assert st["data"]["name"] == "StudioMac"

            # 2. Keyboard works over relay
            kb = await send_via_relay("/key/text", {"text": "Hello via Relay"})
            assert kb["success"] is True
            assert ("key_text", "Hello via Relay") in backend.action_log

            # 3. Mouse movement is rejected over relay (lanOnly)
            mouse = await send_via_relay("/mouse/move", {"dx": "10", "dy": "10"})
            assert mouse["success"] is False
            assert "lanOnly" in mouse["message"]

            # 4. Chunked screenshot over E2EE relay
            c0 = await send_via_relay("/screenshot", {"chunk": "0"})
            assert c0["success"] is True
            total = c0["data"]["chunkCount"]
            assert total >= 2
            full_b64 = c0["data"]["image"]
            for idx in range(1, total):
                ci = await send_via_relay("/screenshot", {"chunk": str(idx)})
                full_b64 += ci["data"]["image"]
            assert base64.b64decode(full_b64) == backend.screenshot_bytes

            # 5. Idle push notification delivered from agent -> relay -> push notifier
            await agent_srv.relay_client.send_idle_event(2)
            await asyncio.sleep(0.05)
            assert any(e["event"] == "pc_idle" and e["payload"].get("idle_hours") == 2 for e in notifier.sent_events)

            # 6. Path traversal over relay is blocked
            bad_path = await send_via_relay("/../etc/passwd")
            assert bad_path["success"] is False
            assert bad_path["message"] == "bad_path"

            # 7. Room hijacking with wrong claim is rejected by relay
            async with relay_client.ws_connect(f"/agent/{agent_cfg.device_id}") as evil_ws:
                ch = await evil_ws.receive_json()
                assert ch["t"] == "challenge"
                wrong_claim = compute_room_claim("WrongToken_999999", agent_cfg.device_id)
                await evil_ws.send_json({"t": "claim", "claim": wrong_claim, "proof": wrong_claim})
                closed_msg = await evil_ws.receive()
                assert closed_msg.type.name in {"CLOSE", "CLOSED"}
