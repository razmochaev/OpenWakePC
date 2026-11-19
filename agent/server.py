"""
OpenWakePC Desktop Agent HTTP API server (`:8765`) and unified command dispatcher.

Implements 40+ LAN & E2EE Relay endpoints, Bearer authentication,
LAN-only enforcement for mouse & file uploads, chunked screenshot delivery for E2EE relay,
custom commands execution, and Buddy Wake (`wol-relay`).
"""

from __future__ import annotations

import base64
import hmac
import logging
import math
import os
import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from aiohttp import web

from common.crypto import send_wol_packets, validate_mac

from .backends import SystemBackend, create_system_backend
from .config import AGENT_VERSION, MAX_UPLOAD_BYTES, AgentConfig, CustomCommandConfig
from .discovery import BonjourAdvertiser
from .relay_client import AgentRelayClient
from .scheduler import ActionScheduler

logger = logging.getLogger("wakepc.agent.server")

AGENT_APP_KEY = web.AppKey("agent", "AgentServer")

ALL_FEATURES = [
    "telemetry",
    "screenshot",
    "screenshot-relay",
    "live-stream",
    "touchpad",
    "hotkeys",
    "send-text",
    "send-file",
    "clipboard-get",
    "custom-commands",
    "audio-output",
    "volume-state",
    "fullscreen-key",
    "idle-action",
    "idle-notify",
    "wol-relay",
]

SCREENSHOT_CHUNK_CHARS = 48 * 1024  # 48 KiB base64 chunks for reliable E2EE relay delivery
SCREENSHOT_CACHE_TTL_SEC = 30.0
MOUSE_DELTA_CLAMP = 5000
SAFE_FILENAME_REGEX = re.compile(r"[^A-Za-z0-9._ -]+")


@dataclass(slots=True)
class CachedScreenshot:
    format: str
    width: int
    height: int
    b64_data: str
    created_at: float


class AgentServer:
    """Core Desktop Agent server serving both LAN HTTP and E2EE Relay commands."""

    def __init__(
        self,
        config: AgentConfig,
        backend: SystemBackend | None = None,
    ) -> None:
        self.config = config
        self.backend = backend or create_system_backend()
        self.bonjour = BonjourAdvertiser(config)
        self.relay_client = AgentRelayClient(
            config=config,
            command_handler=self._dispatch_relay_command,
        )
        self.scheduler = ActionScheduler(
            backend=self.backend,
            on_idle_notify=self.relay_client.send_idle_event,
        )
        self._running_commands: dict[str, subprocess.Popen[Any]] = {}
        self._screenshot_cache: CachedScreenshot | None = None

    def build_app(self) -> web.Application:
        app = web.Application(client_max_size=MAX_UPLOAD_BYTES + 1024 * 1024)
        app[AGENT_APP_KEY] = self

        # Special streaming upload route (LAN only)
        app.router.add_post("/upload", self.handle_upload)

        # Unified catch-all for all 40+ GET/POST command endpoints
        app.router.add_route("GET", "/{tail:.*}", self.handle_http_command)
        app.router.add_route("POST", "/{tail:.*}", self.handle_http_command)

        app.on_startup.append(self._on_startup)
        app.on_cleanup.append(self._on_cleanup)
        return app

    async def _on_startup(self, _app: web.Application) -> None:
        self.scheduler.start()
        self.bonjour.start()
        self.relay_client.start()

    async def _on_cleanup(self, _app: web.Application) -> None:
        await self.relay_client.stop()
        await self.scheduler.stop()
        self.bonjour.stop()
        for proc in list(self._running_commands.values()):
            try:
                proc.terminate()
            except Exception:
                pass
        self._running_commands.clear()

    def _is_authorized(self, request: web.Request) -> tuple[bool, bool]:
        """Return (has_header, token_valid)."""
        header = request.headers.get("Authorization", "")
        if not header:
            return False, False
        if not header.startswith("Bearer "):
            return True, False
        provided = header[len("Bearer ") :].strip()
        return True, hmac.compare_digest(provided.encode("utf-8"), self.config.token.encode("utf-8"))

    async def handle_http_command(self, request: web.Request) -> web.Response:
        path = "/" + request.match_info.get("tail", "").lstrip("/")
        has_auth, valid_auth = self._is_authorized(request)

        # /status without Authorization serves lightweight LAN discovery info;
        # invalid Authorization header always returns 401 so diagnostics can verify tokens.
        if path == "/status" and not has_auth:
            return web.json_response(self._build_public_discovery_status(), status=200)

        if not valid_auth:
            return web.json_response(
                {"success": False, "message": "Unauthorized"},
                status=401,
            )

        query = dict(request.query)
        # Allow JSON body parameters on POST as convenience fallback
        if request.method == "POST" and request.can_read_body:
            try:
                if request.content_type == "application/json":
                    body = await request.json()
                    if isinstance(body, dict):
                        for k, v in body.items():
                            query.setdefault(str(k), str(v))
            except Exception:
                pass

        result, status_code = await self.dispatch_command(path, query, via_relay=False)
        return web.json_response(result, status=status_code)

    async def handle_upload(self, request: web.Request) -> web.Response:
        _, valid_auth = self._is_authorized(request)
        if not valid_auth:
            return web.json_response({"success": False, "message": "Unauthorized"}, status=401)

        raw_name = request.query.get("name", "upload.bin")
        safe_name = _sanitize_filename(raw_name)
        downloads = Path(self.config.downloads_dir)
        downloads.mkdir(parents=True, exist_ok=True)
        dest = _unique_destination(downloads, safe_name)

        total_bytes = 0
        try:
            with dest.open("wb") as fp:
                async for chunk in request.content.iter_chunked(64 * 1024):
                    total_bytes += len(chunk)
                    if total_bytes > MAX_UPLOAD_BYTES:
                        fp.close()
                        dest.unlink(missing_ok=True)
                        return web.json_response(
                            {"success": False, "message": "File exceeds 500 MB limit"},
                            status=413,
                        )
                    fp.write(chunk)
        except Exception as exc:
            dest.unlink(missing_ok=True)
            return web.json_response({"success": False, "message": str(exc)}, status=500)

        return web.json_response(
            self._ok(
                message=f"Saved {dest.name}",
                data={"name": dest.name, "bytes": total_bytes},
            )
        )

    async def _dispatch_relay_command(self, path: str, query: dict[str, str]) -> dict[str, Any]:
        result, _ = await self.dispatch_command(path, query, via_relay=True)
        return result

    async def dispatch_command(
        self,
        path: str,
        query: dict[str, str],
        *,
        via_relay: bool,
    ) -> tuple[dict[str, Any], int]:
        """Execute any documented Wake PC Agent endpoint and return (ApiResponse dict, HTTP status)."""
        norm_path = "/" + path.strip("/")
        if norm_path == "/":
            norm_path = "/status"

        # Enforce LAN-only endpoints when arriving via E2EE relay
        if via_relay and (norm_path.startswith("/mouse/") or norm_path == "/upload"):
            return self._err("This feature is available on local Wi-Fi only (lanOnly)"), 403

        # 1. Status & Telemetry
        if norm_path == "/status":
            vol, muted = self.backend.get_volume_state()
            mic_vol, mic_muted = self.backend.get_mic_state()
            sched = self.scheduler.get_status()
            data = {
                "mac": self.config.mac,
                "bcast": self.config.broadcast,
                "name": self.config.name,
                "type": self.config.device_type,
                "deviceId": self.config.device_id,
                "agentVersion": AGENT_VERSION,
                "features": ALL_FEATURES,
                "volume": vol,
                "muted": muted,
                "micVolume": mic_vol,
                "micMuted": mic_muted,
                "brightness": self.backend.get_brightness(),
                **sched,
            }
            return (
                self._ok(
                    message="Online",
                    data=data,
                    diagnostics=self.backend.get_diagnostics(),
                ),
                200,
            )

        if norm_path == "/telemetry":
            return self._ok(data=self.backend.get_telemetry()), 200

        # 2. Power commands & Buddy Wake
        if norm_path in {"/shutdown", "/restart", "/sleep", "/hibernate", "/lock", "/display-off", "/display-on"}:
            action = norm_path.lstrip("/")
            ok, msg = self.backend.power_action(action)
            return (self._ok(message=msg), 200) if ok else (self._err(msg), 500)

        if norm_path == "/wake-other":
            mac = query.get("mac", "").strip()
            if not validate_mac(mac):
                return self._err("Invalid MAC address"), 400
            bcast = query.get("bcast") or self.config.broadcast
            wol_port = _parse_int(query.get("wolPort"), self.config.wol_port, 1, 65535)
            try:
                sent = send_wol_packets(mac, broadcast=bcast, port=wol_port, repeat=3)
            except Exception as exc:
                return self._err(f"WoL failed: {exc}"), 500
            return self._ok(message=f"Sent {sent} WoL packets to {mac}", data={"mac": mac.upper()}), 200

        # 3. Scheduled actions & Idle automation
        if norm_path in {"/shutdown-in", "/restart-in", "/sleep-in"}:
            action = norm_path.lstrip("/").replace("-in", "")
            minutes = _parse_int(query.get("minutes"), -1, 1, 1440)
            if minutes < 1:
                return self._err("Parameter 'minutes' (1..1440) is required"), 400
            status = self.scheduler.schedule_power(action, minutes)
            return self._ok(message=f"Scheduled {action} in {minutes} min", data=status), 200

        if norm_path == "/scheduled-status":
            return self._ok(data=self.scheduler.get_status()), 200

        if norm_path == "/cancel-scheduled":
            status = self.scheduler.cancel_scheduled()
            return self._ok(message="Scheduled action cancelled", data=status), 200

        if norm_path == "/idle-action":
            action = query.get("action")
            minutes = _parse_int(query.get("minutes"), 10, 1, 240)
            try:
                status = self.scheduler.set_idle_action(action, minutes)
            except ValueError as exc:
                return self._err(str(exc)), 400
            return self._ok(message="Idle action updated", data=status), 200

        if norm_path == "/idle-notify":
            hours = _parse_int(query.get("hours"), -1, 0, 24)
            try:
                status = self.scheduler.set_idle_notify(hours)
            except ValueError as exc:
                return self._err(str(exc)), 400
            return self._ok(message="Idle notify updated", data=status), 200

        # 4. Volume & Audio Outputs
        if norm_path.startswith("/volume-set/"):
            raw_val = norm_path[len("/volume-set/") :]
            level = _parse_int(raw_val, -1, 0, 100)
            if level < 0:
                return self._err("Volume must be 0..100"), 400
            vol, muted = self.backend.set_volume(level)
            return self._ok(data={"volume": vol, "muted": muted}), 200

        if norm_path == "/volume-up":
            step = _parse_int(query.get("step"), 5, 1, 50)
            vol, muted = self.backend.adjust_volume(step)
            return self._ok(data={"volume": vol, "muted": muted}), 200

        if norm_path == "/volume-down":
            step = _parse_int(query.get("step"), 5, 1, 50)
            vol, muted = self.backend.adjust_volume(-step)
            return self._ok(data={"volume": vol, "muted": muted}), 200

        if norm_path == "/volume-mute":
            vol, muted = self.backend.toggle_mute()
            return self._ok(data={"volume": vol, "muted": muted}), 200

        if norm_path.startswith("/mic-set/"):
            raw_val = norm_path[len("/mic-set/") :]
            level = _parse_int(raw_val, -1, 0, 100)
            if level < 0:
                return self._err("Mic volume must be 0..100"), 400
            mic_vol, mic_muted = self.backend.set_mic_volume(level)
            return self._ok(data={"micVolume": mic_vol, "micMuted": mic_muted}), 200

        if norm_path == "/mic-up":
            step = _parse_int(query.get("step"), 5, 1, 50)
            mic_vol, mic_muted = self.backend.adjust_mic_volume(step)
            return self._ok(data={"micVolume": mic_vol, "micMuted": mic_muted}), 200

        if norm_path == "/mic-down":
            step = _parse_int(query.get("step"), 5, 1, 50)
            mic_vol, mic_muted = self.backend.adjust_mic_volume(-step)
            return self._ok(data={"micVolume": mic_vol, "micMuted": mic_muted}), 200

        if norm_path == "/mic-mute":
            mic_vol, mic_muted = self.backend.toggle_mic_mute()
            return self._ok(data={"micVolume": mic_vol, "micMuted": mic_muted}), 200

        if norm_path == "/audio-outputs":
            return self._ok(data={"outputs": self.backend.list_audio_outputs()}), 200

        if norm_path == "/audio-output/set":
            out_id = query.get("id", "").strip()
            if not out_id:
                return self._err("Missing output id"), 400
            ok = self.backend.set_audio_output(out_id)
            if not ok:
                return self._err("Audio output not found"), 404
            return self._ok(message="Audio output updated", data={"outputs": self.backend.list_audio_outputs()}), 200

        if norm_path == "/audio-inputs":
            return self._ok(data={"inputs": self.backend.list_audio_inputs()}), 200

        if norm_path == "/audio-input/set":
            in_id = query.get("id", "").strip()
            if not in_id:
                return self._err("Missing input id"), 400
            ok = self.backend.set_audio_input(in_id)
            if not ok:
                return self._err("Audio input not found"), 404
            return self._ok(message="Audio input updated", data={"inputs": self.backend.list_audio_inputs()}), 200

        # 5. Brightness
        if norm_path.startswith("/brightness-set/"):
            raw_val = norm_path[len("/brightness-set/") :]
            level = _parse_int(raw_val, -1, 0, 100)
            if level < 0:
                return self._err("Brightness must be 0..100"), 400
            val = self.backend.set_brightness(level)
            return self._ok(data={"brightness": val}), 200

        if norm_path == "/brightness-up":
            step = _parse_int(query.get("step"), 10, 1, 50)
            return self._ok(data={"brightness": self.backend.adjust_brightness(step)}), 200

        if norm_path == "/brightness-down":
            step = _parse_int(query.get("step"), 10, 1, 50)
            return self._ok(data={"brightness": self.backend.adjust_brightness(-step)}), 200

        # 6. Media controls
        if norm_path in {"/media-play-pause", "/media-next", "/media-prev", "/media-fullscreen"}:
            action = norm_path[len("/media-") :]
            ok = self.backend.media_control(action)
            return (self._ok(message=f"Media {action}"), 200) if ok else (self._err("Media action failed"), 500)

        # 7. Screenshot (direct + chunked relay)
        if norm_path == "/screenshot":
            return self._handle_screenshot(query, via_relay=via_relay), 200

        # 8. Running apps
        if norm_path == "/apps":
            return self._ok(data={"apps": self.backend.list_running_apps()}), 200

        if norm_path == "/apps/close":
            app_id = query.get("id", "").strip()
            force = query.get("force", "false").lower() in {"1", "true", "yes"}
            if not app_id:
                return self._err("Missing app id"), 400
            ok, msg = self.backend.close_app(app_id, force=force)
            return (self._ok(message=msg), 200) if ok else (self._err(msg), 409)

        # 9. Custom commands
        if norm_path == "/commands":
            return self._ok(data={"commands": self._list_custom_commands()}), 200

        if norm_path == "/command/run":
            cmd_id = query.get("id", "").strip()
            return self._run_custom_command(cmd_id)

        if norm_path == "/command/close":
            cmd_id = query.get("id", "").strip()
            return self._close_custom_command(cmd_id)

        # 10. URL & Clipboard
        if norm_path == "/open-url":
            url = query.get("url", "").strip()
            parsed = urlparse(url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                return self._err("Only http:// and https:// URLs are supported"), 400
            self.backend.open_url(url)
            return self._ok(message="URL opened"), 200

        if norm_path == "/clipboard":
            text = query.get("text", "")
            self.backend.set_clipboard(text)
            return self._ok(message="Clipboard updated"), 200

        if norm_path == "/clipboard/get":
            text, truncated = self.backend.get_clipboard()
            return self._ok(data={"text": text, "truncated": truncated}), 200

        # 11. Touchpad & Keyboard
        if norm_path == "/mouse/move":
            dx = _clamp(_parse_int(query.get("dx"), 0, -100000, 100000), -MOUSE_DELTA_CLAMP, MOUSE_DELTA_CLAMP)
            dy = _clamp(_parse_int(query.get("dy"), 0, -100000, 100000), -MOUSE_DELTA_CLAMP, MOUSE_DELTA_CLAMP)
            self.backend.mouse_move(dx, dy)
            return self._ok(), 200

        if norm_path == "/mouse/scroll":
            dx = _clamp(_parse_int(query.get("dx"), 0, -100000, 100000), -MOUSE_DELTA_CLAMP, MOUSE_DELTA_CLAMP)
            dy = _clamp(_parse_int(query.get("dy"), 0, -100000, 100000), -MOUSE_DELTA_CLAMP, MOUSE_DELTA_CLAMP)
            self.backend.mouse_scroll(dx, dy)
            return self._ok(), 200

        if norm_path == "/mouse/click":
            button = query.get("button", "left").lower()
            if button not in {"left", "right"}:
                return self._err("Button must be 'left' or 'right'"), 400
            count = _parse_int(query.get("count"), 1, 1, 3)
            self.backend.mouse_click(button, count)
            return self._ok(), 200

        if norm_path == "/mouse/drag":
            state = query.get("state", "").lower()
            if state not in {"down", "up"}:
                return self._err("State must be 'down' or 'up'"), 400
            self.backend.mouse_drag(state)
            return self._ok(), 200

        if norm_path == "/key/text":
            text = query.get("text", "")
            self.backend.key_text(text)
            return self._ok(), 200

        if norm_path == "/key/press":
            key = query.get("key", "").strip()
            if not key:
                return self._err("Missing key parameter"), 400
            raw_mods = query.get("mods", "")
            mods = [m.strip() for m in raw_mods.split(",") if m.strip()]
            self.backend.key_press(key, mods)
            return self._ok(), 200

        if norm_path == "/stream/frame":
            shot = self.backend.take_screenshot()
            return self._ok(
                data={
                    "format": shot.format,
                    "width": shot.width,
                    "height": shot.height,
                    "image": base64.b64encode(shot.data).decode("ascii"),
                    "audioRate": 24000,
                    "audioChannels": 1,
                    "audioSeq": 0,
                }
            ), 200

        if norm_path == "/stream/stop":
            return self._ok(message="Stream stopped"), 200

        return self._err(f"Unknown endpoint: {norm_path}"), 404

    def _handle_screenshot(self, query: dict[str, str], *, via_relay: bool) -> dict[str, Any]:
        chunk_param = query.get("chunk")
        force_chunks = via_relay or query.get("chunks") in {"1", "true"} or chunk_param is not None

        now = time.time()
        need_fresh = (
            self._screenshot_cache is None
            or chunk_param is None
            or chunk_param == "0"
            or (now - self._screenshot_cache.created_at) > SCREENSHOT_CACHE_TTL_SEC
        )
        if need_fresh:
            shot = self.backend.take_screenshot()
            self._screenshot_cache = CachedScreenshot(
                format=shot.format,
                width=shot.width,
                height=shot.height,
                b64_data=base64.b64encode(shot.data).decode("ascii"),
                created_at=now,
            )

        cached = self._screenshot_cache
        assert cached is not None

        if not force_chunks:
            return self._ok(
                data={
                    "format": cached.format,
                    "width": cached.width,
                    "height": cached.height,
                    "image": cached.b64_data,
                    "chunkIndex": 0,
                    "chunkCount": 1,
                }
            )

        chunk_count = max(1, math.ceil(len(cached.b64_data) / SCREENSHOT_CHUNK_CHARS))
        chunk_idx = _parse_int(chunk_param, 0, 0, chunk_count - 1)
        start = chunk_idx * SCREENSHOT_CHUNK_CHARS
        end = start + SCREENSHOT_CHUNK_CHARS
        return self._ok(
            data={
                "format": cached.format,
                "width": cached.width,
                "height": cached.height,
                "image": cached.b64_data[start:end],
                "chunkIndex": chunk_idx,
                "chunkCount": chunk_count,
            }
        )

    def _list_custom_commands(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for cmd in self.config.custom_commands:
            proc = self._running_commands.get(cmd.id)
            running = proc is not None and proc.poll() is None
            items.append(
                {
                    "id": cmd.id,
                    "name": cmd.name,
                    "icon": cmd.icon,
                    "iconImage": None,
                    "running": running,
                    "closable": cmd.closable,
                }
            )
        return items

    def _find_custom_command(self, cmd_id: str) -> CustomCommandConfig | None:
        for cmd in self.config.custom_commands:
            if cmd.id == cmd_id:
                return cmd
        return None

    def _run_custom_command(self, cmd_id: str) -> tuple[dict[str, Any], int]:
        cmd = self._find_custom_command(cmd_id)
        if cmd is None:
            return self._err("Command not found"), 404
        try:
            proc = subprocess.Popen(cmd.command)
            self._running_commands[cmd.id] = proc
            return self._ok(message=f"Started {cmd.name}", data={"commands": self._list_custom_commands()}), 200
        except OSError as exc:
            return self._err(str(exc)), 500

    def _close_custom_command(self, cmd_id: str) -> tuple[dict[str, Any], int]:
        cmd = self._find_custom_command(cmd_id)
        if cmd is None:
            return self._err("Command not found"), 404
        proc = self._running_commands.pop(cmd.id, None)
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        return self._ok(message=f"Closed {cmd.name}", data={"commands": self._list_custom_commands()}), 200

    def _build_public_discovery_status(self) -> dict[str, Any]:
        return {
            "success": True,
            "message": "OpenWakePC Agent",
            "data": {
                "mac": self.config.mac,
                "bcast": self.config.broadcast,
                "name": self.config.name,
                "type": self.config.device_type,
                "deviceId": self.config.device_id,
                "agentVersion": AGENT_VERSION,
                "features": ALL_FEATURES,
            },
            "features": ALL_FEATURES,
        }

    def _ok(
        self,
        *,
        message: str = "OK",
        data: dict[str, Any] | None = None,
        diagnostics: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "success": True,
            "message": message,
            "features": ALL_FEATURES,
        }
        if diagnostics is not None:
            payload["diagnostics"] = diagnostics
        if data is not None:
            payload["data"] = data
        return payload

    def _err(self, message: str) -> dict[str, Any]:
        return {
            "success": False,
            "message": message,
            "features": ALL_FEATURES,
        }


def _parse_int(raw: str | None, default: int, min_val: int, max_val: int) -> int:
    if raw is None:
        return default
    try:
        val = int(float(raw))
    except (TypeError, ValueError):
        return default
    return _clamp(val, min_val, max_val)


def _clamp(val: int, low: int, high: int) -> int:
    return max(low, min(high, val))


def _sanitize_filename(name: str) -> str:
    base = os.path.basename(name).strip()
    cleaned = SAFE_FILENAME_REGEX.sub("_", base).strip(". ")
    return cleaned[:200] or "upload.bin"


def _unique_destination(directory: Path, filename: str) -> Path:
    candidate = directory / filename
    if not candidate.exists():
        return candidate
    stem = candidate.stem
    suffix = candidate.suffix
    for i in range(1, 10000):
        alt = directory / f"{stem}_{i}{suffix}"
        if not alt.exists():
            return alt
    return directory / f"{stem}_{int(time.time())}{suffix}"


def create_agent_app(
    config: AgentConfig,
    backend: SystemBackend | None = None,
) -> web.Application:
    """Factory helper returning a configured aiohttp Application for the Desktop Agent."""
    server = AgentServer(config=config, backend=backend)
    return server.build_app()
