"""Comprehensive unit and API tests for the Open Wake PC Desktop Agent."""

from __future__ import annotations

import base64
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest
from aiohttp.test_utils import TestClient, TestServer

from agent.backends import MockSystemBackend
from agent.config import AgentConfig, CustomCommandConfig
from agent.server import AGENT_APP_KEY, create_agent_app


def _make_config(tmp_path: Path) -> AgentConfig:
    return AgentConfig(
        name="TestPC",
        device_id="test-device-001",
        device_type="windows",
        token="AgentTestToken_123456",
        mac="AA:BB:CC:DD:EE:FF",
        ip="192.168.1.50",
        broadcast="192.168.1.255",
        api_port=8765,
        wol_port=9,
        downloads_dir=str(tmp_path / "downloads"),
        enable_bonjour=False,
        custom_commands=[
            CustomCommandConfig(
                id="sleep-cmd",
                name="Sleep Process",
                command=[sys.executable, "-c", "import time; time.sleep(30)"],
                icon="terminal",
                closable=True,
            )
        ],
    )


def test_qr_url_and_config_persistence(tmp_path: Path) -> None:
    cfg_path = tmp_path / "agent.json"
    cfg = _make_config(tmp_path)
    cfg.save(cfg_path)
    loaded = AgentConfig.load_or_create(cfg_path)
    assert loaded.device_id == cfg.device_id
    assert loaded.token == cfg.token
    assert len(loaded.custom_commands) == 1

    url = loaded.build_qr_url()
    parsed = urlparse(url)
    assert parsed.scheme == "wakepc"
    assert parsed.netloc == "config"
    qs = parse_qs(parsed.query)
    assert qs["mac"] == ["AA:BB:CC:DD:EE:FF"]
    assert qs["token"] == ["AgentTestToken_123456"]
    assert qs["deviceType"] == ["windows"]
    assert qs["deviceId"] == ["test-device-001"]
    assert "AgentTestToken_123456" not in loaded.build_masked_qr_url()


@pytest.mark.asyncio
async def test_agent_all_http_endpoints(tmp_path: Path) -> None:
    cfg = _make_config(tmp_path)
    backend = MockSystemBackend(
        stubborn_app_ids={"101"},
        screenshot_bytes=b"X" * 90000,  # Forces multiple chunks in chunked mode
    )
    app = create_agent_app(cfg, backend=backend)
    headers = {"Authorization": f"Bearer {cfg.token}"}

    async with TestClient(TestServer(app)) as client:
        # Public /status discovery works without token
        pub = await client.get("/status")
        assert pub.status == 200
        pub_json = await pub.json()
        assert pub_json["data"]["mac"] == "AA:BB:CC:DD:EE:FF"

        # Wrong token returns 401
        bad = await client.get("/status", headers={"Authorization": "Bearer wrong_token_999"})
        assert bad.status == 401

        # Protected endpoints reject missing auth
        no_auth = await client.get("/telemetry")
        assert no_auth.status == 401

        # Authenticated /status includes diagnostics and features
        st = await client.get("/status", headers=headers)
        assert st.status == 200
        st_json = await st.json()
        assert st_json["success"] is True
        assert "diagnostics" in st_json
        assert "telemetry" in st_json["features"]

        # Telemetry
        tel = await (await client.get("/telemetry", headers=headers)).json()
        assert tel["data"]["cpuLoad"] == 12.5
        assert tel["data"]["ramTotalGb"] == 32.0

        # Power actions
        for ep in ("/shutdown", "/restart", "/sleep", "/hibernate", "/lock", "/display-off", "/display-on"):
            r = await client.post(ep, headers=headers)
            assert r.status == 200
            assert (await r.json())["success"] is True

        # Volume & Audio outputs
        r = await (await client.post("/volume-set/65", headers=headers)).json()
        assert r["data"]["volume"] == 65
        r = await (await client.post("/volume-up", headers=headers)).json()
        assert r["data"]["volume"] == 70
        r = await (await client.post("/volume-down", headers=headers)).json()
        assert r["data"]["volume"] == 65
        r = await (await client.post("/volume-mute", headers=headers)).json()
        assert r["data"]["muted"] is True

        outs = await (await client.get("/audio-outputs", headers=headers)).json()
        assert len(outs["data"]["outputs"]) == 2
        sw = await (await client.post("/audio-output/set?id=headphones", headers=headers)).json()
        assert sw["success"] is True
        assert any(o["id"] == "headphones" and o["isDefault"] for o in sw["data"]["outputs"])

        # Brightness
        r = await (await client.post("/brightness-set/40", headers=headers)).json()
        assert r["data"]["brightness"] == 40
        r = await (await client.post("/brightness-up", headers=headers)).json()
        assert r["data"]["brightness"] == 50
        r = await (await client.post("/brightness-down", headers=headers)).json()
        assert r["data"]["brightness"] == 40

        # Media
        for ep in ("/media-play-pause", "/media-next", "/media-prev", "/media-fullscreen"):
            assert (await client.post(ep, headers=headers)).status == 200

        # Screenshot direct & chunked
        direct = await (await client.get("/screenshot", headers=headers)).json()
        assert direct["data"]["chunkCount"] == 1
        assert base64.b64decode(direct["data"]["image"]) == backend.screenshot_bytes

        c0 = await (await client.get("/screenshot?chunk=0", headers=headers)).json()
        total_chunks = c0["data"]["chunkCount"]
        assert total_chunks >= 2
        reassembled = c0["data"]["image"]
        for idx in range(1, total_chunks):
            ci = await (await client.get(f"/screenshot?chunk={idx}", headers=headers)).json()
            reassembled += ci["data"]["image"]
        assert base64.b64decode(reassembled) == backend.screenshot_bytes

        # Running apps (soft fail -> force succeed)
        apps = await (await client.get("/apps", headers=headers)).json()
        assert len(apps["data"]["apps"]) == 2
        soft = await client.post("/apps/close?id=101", headers=headers)
        assert soft.status == 409
        forced = await client.post("/apps/close?id=101&force=true", headers=headers)
        assert forced.status == 200

        # Custom commands run & close
        cmds = await (await client.get("/commands", headers=headers)).json()
        assert cmds["data"]["commands"][0]["running"] is False
        run_res = await (await client.post("/command/run?id=sleep-cmd", headers=headers)).json()
        assert run_res["data"]["commands"][0]["running"] is True
        close_res = await (await client.post("/command/close?id=sleep-cmd", headers=headers)).json()
        assert close_res["data"]["commands"][0]["running"] is False

        # Open URL & Clipboard
        bad_url = await client.post("/open-url?url=file:///etc/passwd", headers=headers)
        assert bad_url.status == 400
        ok_url = await client.post("/open-url?url=https://example.com", headers=headers)
        assert ok_url.status == 200

        await client.post("/clipboard?text=hello+world", headers=headers)
        cb = await (await client.get("/clipboard/get", headers=headers)).json()
        assert cb["data"] == {"text": "hello world", "truncated": False}

        # File upload + path traversal protection
        up = await client.post(
            "/upload?name=../../evil/photo.jpg",
            headers={**headers, "Content-Type": "application/octet-stream"},
            data=b"JPEGDATA12345",
        )
        assert up.status == 200
        up_json = await up.json()
        saved_file = Path(cfg.downloads_dir) / up_json["data"]["name"]
        assert saved_file.parent == Path(cfg.downloads_dir)
        assert saved_file.read_bytes() == b"JPEGDATA12345"

        # Touchpad & keyboard
        await client.post("/mouse/move?dx=99999&dy=-99999", headers=headers)
        assert ("mouse_move", (5000, -5000)) in backend.action_log
        await client.post("/mouse/scroll?dx=0&dy=-12", headers=headers)
        await client.post("/mouse/click?button=right&count=1", headers=headers)
        await client.post("/mouse/drag?state=down", headers=headers)
        await client.post("/mouse/drag?state=up", headers=headers)
        await client.post("/key/text?text=hello", headers=headers)
        await client.post("/key/press?key=tab&mods=alt,shift", headers=headers)
        assert ("key_press", ("tab", ["alt", "shift"])) in backend.action_log

        # Scheduled power & idle actions
        sch = await (await client.post("/shutdown-in?minutes=15", headers=headers)).json()
        assert sch["data"]["hasScheduled"] is True
        assert sch["data"]["action"] == "shutdown"
        can = await (await client.post("/cancel-scheduled", headers=headers)).json()
        assert can["data"]["hasScheduled"] is False

        idle = await (await client.post("/idle-action?action=sleep&minutes=10", headers=headers)).json()
        assert idle["data"]["idleAction"] == "sleep"
        inot = await (await client.post("/idle-notify?hours=2", headers=headers)).json()
        assert inot["data"]["idleNotifyHours"] == 2

        # Trigger scheduler idle tick directly
        agent_srv = app[AGENT_APP_KEY]
        backend.cpu_load = 2.0
        agent_srv.scheduler.idle_streak_seconds = 595
        await agent_srv.scheduler.tick()
        assert ("power", "sleep") in backend.action_log
