"""
Cross-platform OS backend adapters for the Desktop Agent.

Provides:
- SystemBackend: abstract protocol covering power, audio, brightness, media,
  telemetry, diagnostics, screenshot, apps, clipboard, URL opening, mouse/keyboard.
- MockSystemBackend: deterministic in-memory backend for unit/integration tests.
- WindowsSystemBackend / MacOSSystemBackend / LinuxSystemBackend: real OS implementations
  with safe fallbacks when optional desktop packages (psutil/mss/pynput) are absent.
"""

from __future__ import annotations

import abc
import base64
import io
import logging
import os
import platform
import shutil
import subprocess
import time
import webbrowser
from dataclasses import dataclass, field
from typing import Any

from .config import AGENT_VERSION

logger = logging.getLogger("wakepc.agent.backend")

# Minimal valid 1x1 PNG used as fallback when no display server is attached
FALLBACK_PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


@dataclass(slots=True)
class ScreenshotResult:
    format: str
    width: int
    height: int
    data: bytes


class SystemBackend(abc.ABC):
    """Abstract OS backend interface for Wake PC Agent."""

    @abc.abstractmethod
    def get_telemetry(self) -> dict[str, Any]:
        """Return cpuLoad, ramLoad, ramUsedGb, ramTotalGb, uptimeSeconds."""

    @abc.abstractmethod
    def get_diagnostics(self) -> dict[str, Any]:
        """Return DiagnosticsInfo dictionary."""

    @abc.abstractmethod
    def power_action(self, action: str) -> tuple[bool, str]:
        """Execute shutdown, restart, sleep, hibernate, lock, display-off, display-on."""

    @abc.abstractmethod
    def get_volume_state(self) -> tuple[int, bool]:
        """Return (volume 0..100, muted)."""

    @abc.abstractmethod
    def set_volume(self, level: int) -> tuple[int, bool]:
        """Set volume 0..100 and return updated (volume, muted)."""

    @abc.abstractmethod
    def adjust_volume(self, delta: int) -> tuple[int, bool]:
        """Change volume by delta and return updated (volume, muted)."""

    @abc.abstractmethod
    def toggle_mute(self) -> tuple[int, bool]:
        """Toggle mute state and return updated (volume, muted)."""

    def get_mic_state(self) -> tuple[int, bool]:
        """Return (mic_volume 0..100, mic_muted)."""
        return 50, False

    def set_mic_volume(self, level: int) -> tuple[int, bool]:
        """Set microphone volume 0..100 and return updated (mic_volume, mic_muted)."""
        clamped = max(0, min(100, level))
        return clamped, clamped == 0

    def adjust_mic_volume(self, delta: int) -> tuple[int, bool]:
        """Change microphone volume by delta and return updated (mic_volume, mic_muted)."""
        vol, _ = self.get_mic_state()
        return self.set_mic_volume(vol + delta)

    def toggle_mic_mute(self) -> tuple[int, bool]:
        """Toggle microphone mute state and return updated (mic_volume, mic_muted)."""
        vol, muted = self.get_mic_state()
        return (50, False) if muted else (0, True)

    @abc.abstractmethod
    def list_audio_outputs(self) -> list[dict[str, Any]]:
        """Return AudioOutputInfo list [{id, name, isDefault}]."""

    @abc.abstractmethod
    def set_audio_output(self, output_id: str) -> bool:
        """Select audio output device by id."""

    def list_audio_inputs(self) -> list[dict[str, Any]]:
        """Return AudioInput list [{id, name, isDefault}]."""
        return [{"id": "default", "name": "System Default", "isDefault": True}]

    def set_audio_input(self, input_id: str) -> bool:
        """Select audio input device by id."""
        return input_id == "default"

    @abc.abstractmethod
    def get_brightness(self) -> int:
        """Return screen brightness 0..100."""

    @abc.abstractmethod
    def set_brightness(self, level: int) -> int:
        """Set screen brightness 0..100."""

    @abc.abstractmethod
    def adjust_brightness(self, delta: int) -> int:
        """Adjust screen brightness by delta."""

    @abc.abstractmethod
    def media_control(self, action: str) -> bool:
        """Execute play-pause, next, prev, or fullscreen."""

    @abc.abstractmethod
    def take_screenshot(self) -> ScreenshotResult:
        """Capture primary screen as JPEG or PNG."""

    @abc.abstractmethod
    def list_running_apps(self) -> list[dict[str, Any]]:
        """Return RunningAppInfo list [{id, name, icon, iconImage}]."""

    @abc.abstractmethod
    def close_app(self, app_id: str, force: bool = False) -> tuple[bool, str]:
        """Close application softly or forcefully."""

    @abc.abstractmethod
    def open_url(self, url: str) -> bool:
        """Open HTTP(S) URL in the default browser."""

    @abc.abstractmethod
    def set_clipboard(self, text: str) -> bool:
        """Write text to the OS clipboard."""

    @abc.abstractmethod
    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        """Read text from the OS clipboard, returning (text, truncated)."""

    @abc.abstractmethod
    def mouse_move(self, dx: int, dy: int) -> None:
        """Move cursor relatively by (dx, dy)."""

    @abc.abstractmethod
    def mouse_scroll(self, dx: int, dy: int) -> None:
        """Scroll by (dx, dy)."""

    @abc.abstractmethod
    def mouse_click(self, button: str, count: int) -> None:
        """Click left or right mouse button count times."""

    @abc.abstractmethod
    def mouse_drag(self, state: str) -> None:
        """Press ('down') or release ('up') primary mouse button for dragging."""

    @abc.abstractmethod
    def key_text(self, text: str) -> None:
        """Type Unicode text string."""

    @abc.abstractmethod
    def key_press(self, key: str, mods: list[str]) -> None:
        """Press special key with optional modifier keys."""

    def get_network_bytes(self) -> int:
        """Return cumulative network bytes sent+received (used for idle detection)."""
        try:
            import psutil  # type: ignore

            counters = psutil.net_io_counters()
            return int(counters.bytes_sent + counters.bytes_recv) if counters else 0
        except Exception:
            return 0


@dataclass
class MockSystemBackend(SystemBackend):
    """In-memory deterministic OS backend for tests and headless dry-runs."""

    volume: int = 50
    muted: bool = False
    mic_volume: int = 50
    mic_muted: bool = False
    _last_mic_volume: int = 50
    brightness: int = 75
    clipboard: str = "Hello from PC clipboard"
    cpu_load: float = 12.5
    ram_used_gb: float = 8.4
    ram_total_gb: float = 32.0
    uptime_seconds: int = 3600
    audio_outputs: list[dict[str, Any]] = field(
        default_factory=lambda: [
            {"id": "speakers", "name": "Desktop Speakers", "isDefault": True},
            {"id": "headphones", "name": "Studio Headphones", "isDefault": False},
        ]
    )
    audio_inputs: list[dict[str, Any]] = field(
        default_factory=lambda: [
            {"id": "mic_builtin", "name": "Built-in Microphone", "isDefault": True},
            {"id": "mic_usb", "name": "USB Studio Mic", "isDefault": False},
        ]
    )
    running_apps: list[dict[str, Any]] = field(
        default_factory=lambda: [
            {"id": "101", "name": "Browser", "icon": "globe", "iconImage": None},
            {"id": "202", "name": "Code Editor", "icon": "chevron.left.forwardslash.chevron.right", "iconImage": None},
        ]
    )
    stubborn_app_ids: set[str] = field(default_factory=set)
    action_log: list[tuple[str, Any]] = field(default_factory=list)
    screenshot_bytes: bytes = FALLBACK_PNG_BYTES
    network_bytes: int = 0

    def get_telemetry(self) -> dict[str, Any]:
        ram_load = round((self.ram_used_gb / self.ram_total_gb) * 100.0, 1)
        return {
            "cpuLoad": self.cpu_load,
            "ramLoad": ram_load,
            "ramUsedGb": self.ram_used_gb,
            "ramTotalGb": self.ram_total_gb,
            "uptimeSeconds": self.uptime_seconds,
        }

    def get_diagnostics(self) -> dict[str, Any]:
        return {
            "wifiConnected": False,
            "primaryAdapter": "Ethernet",
            "hasMultipleAdapters": False,
            "isVirtualAdapter": False,
            "agentVersion": AGENT_VERSION,
            "networkProfile": "private",
            "thirdPartyAntivirus": False,
            "lanReachable": True,
            "problems": [],
        }

    def power_action(self, action: str) -> tuple[bool, str]:
        self.action_log.append(("power", action))
        return True, f"Executed {action}"

    def get_volume_state(self) -> tuple[int, bool]:
        return self.volume, self.muted

    def set_volume(self, level: int) -> tuple[int, bool]:
        self.volume = max(0, min(100, level))
        if self.volume > 0:
            self.muted = False
        self.action_log.append(("volume_set", self.volume))
        return self.volume, self.muted

    def adjust_volume(self, delta: int) -> tuple[int, bool]:
        return self.set_volume(self.volume + delta)

    def toggle_mute(self) -> tuple[int, bool]:
        self.muted = not self.muted
        self.action_log.append(("volume_mute", self.muted))
        return self.volume, self.muted

    def get_mic_state(self) -> tuple[int, bool]:
        return (0 if self.mic_muted else self.mic_volume), self.mic_muted

    def set_mic_volume(self, level: int) -> tuple[int, bool]:
        self.mic_volume = max(0, min(100, level))
        if self.mic_volume > 0:
            self._last_mic_volume = self.mic_volume
            self.mic_muted = False
        else:
            self.mic_muted = True
        self.action_log.append(("mic_set", self.mic_volume))
        return self.mic_volume, self.mic_muted

    def adjust_mic_volume(self, delta: int) -> tuple[int, bool]:
        base = self._last_mic_volume if self.mic_muted else self.mic_volume
        return self.set_mic_volume(base + delta)

    def toggle_mic_mute(self) -> tuple[int, bool]:
        if not self.mic_muted and self.mic_volume > 0:
            self._last_mic_volume = self.mic_volume
            self.mic_muted = True
            self.action_log.append(("mic_mute", True))
            return 0, True
        restored = max(10, self._last_mic_volume)
        self.mic_volume = restored
        self.mic_muted = False
        self.action_log.append(("mic_mute", False))
        return restored, False

    def list_audio_outputs(self) -> list[dict[str, Any]]:
        return [dict(o) for o in self.audio_outputs]

    def set_audio_output(self, output_id: str) -> bool:
        found = any(o["id"] == output_id for o in self.audio_outputs)
        if not found:
            return False
        for o in self.audio_outputs:
            o["isDefault"] = o["id"] == output_id
        self.action_log.append(("audio_output", output_id))
        return True

    def list_audio_inputs(self) -> list[dict[str, Any]]:
        return [dict(i) for i in self.audio_inputs]

    def set_audio_input(self, input_id: str) -> bool:
        found = any(i["id"] == input_id for i in self.audio_inputs)
        if not found:
            return False
        for i in self.audio_inputs:
            i["isDefault"] = i["id"] == input_id
        self.action_log.append(("audio_input", input_id))
        return True

    def get_brightness(self) -> int:
        return self.brightness

    def set_brightness(self, level: int) -> int:
        self.brightness = max(0, min(100, level))
        self.action_log.append(("brightness_set", self.brightness))
        return self.brightness

    def adjust_brightness(self, delta: int) -> int:
        return self.set_brightness(self.brightness + delta)

    def media_control(self, action: str) -> bool:
        self.action_log.append(("media", action))
        return True

    def take_screenshot(self) -> ScreenshotResult:
        self.action_log.append(("screenshot", None))
        return ScreenshotResult(format="png", width=1920, height=1080, data=self.screenshot_bytes)

    def list_running_apps(self) -> list[dict[str, Any]]:
        return [dict(a) for a in self.running_apps]

    def close_app(self, app_id: str, force: bool = False) -> tuple[bool, str]:
        if app_id in self.stubborn_app_ids and not force:
            return False, "Application did not close"
        before = len(self.running_apps)
        self.running_apps = [a for a in self.running_apps if a["id"] != app_id]
        if len(self.running_apps) == before:
            return False, "Application not found"
        self.action_log.append(("close_app", (app_id, force)))
        return True, "Application closed"

    def open_url(self, url: str) -> bool:
        self.action_log.append(("open_url", url))
        return True

    def set_clipboard(self, text: str) -> bool:
        self.clipboard = text
        self.action_log.append(("clipboard_set", text))
        return True

    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        if len(self.clipboard) > max_chars:
            return self.clipboard[:max_chars], True
        return self.clipboard, False

    def mouse_move(self, dx: int, dy: int) -> None:
        self.action_log.append(("mouse_move", (dx, dy)))

    def mouse_scroll(self, dx: int, dy: int) -> None:
        self.action_log.append(("mouse_scroll", (dx, dy)))

    def mouse_click(self, button: str, count: int) -> None:
        self.action_log.append(("mouse_click", (button, count)))

    def mouse_drag(self, state: str) -> None:
        self.action_log.append(("mouse_drag", state))

    def key_text(self, text: str) -> None:
        self.action_log.append(("key_text", text))

    def key_press(self, key: str, mods: list[str]) -> None:
        self.action_log.append(("key_press", (key, mods)))

    def get_network_bytes(self) -> int:
        return self.network_bytes


class BaseRealSystemBackend(SystemBackend):
    """Shared cross-platform implementation using optional psutil, mss, Pillow, and pynput."""

    def __init__(self) -> None:
        self._volume = 50
        self._muted = False
        self._mic_volume = 50
        self._mic_muted = False
        self._last_mic_volume = 75
        self._brightness = 80
        self._start_time = time.time()

    def get_telemetry(self) -> dict[str, Any]:
        try:
            import psutil  # type: ignore

            vm = psutil.virtual_memory()
            boot = psutil.boot_time()
            return {
                "cpuLoad": round(float(psutil.cpu_percent(interval=0.05)), 1),
                "ramLoad": round(float(vm.percent), 1),
                "ramUsedGb": round(vm.used / (1024**3), 2),
                "ramTotalGb": round(vm.total / (1024**3), 2),
                "uptimeSeconds": max(0, int(time.time() - boot)),
            }
        except Exception:
            return {
                "cpuLoad": 0.0,
                "ramLoad": 0.0,
                "ramUsedGb": 0.0,
                "ramTotalGb": 0.0,
                "uptimeSeconds": int(time.time() - self._start_time),
            }

    def get_diagnostics(self) -> dict[str, Any]:
        adapters: list[str] = []
        wifi = False
        virtual = False
        try:
            import psutil  # type: ignore

            for name, stats in psutil.net_if_stats().items():
                if stats.isup and not name.lower().startswith("lo"):
                    adapters.append(name)
                    low = name.lower()
                    if any(k in low for k in ("wi-fi", "wifi", "wlan", "en0")):
                        wifi = True
                    if any(k in low for k in ("docker", "veth", "vmware", "virtualbox", "utun", "tun")):
                        virtual = True
        except Exception:
            pass
        return {
            "wifiConnected": wifi,
            "primaryAdapter": adapters[0] if adapters else "unknown",
            "hasMultipleAdapters": len(adapters) > 1,
            "isVirtualAdapter": virtual,
            "agentVersion": AGENT_VERSION,
            "networkProfile": "private",
            "thirdPartyAntivirus": False,
            "lanReachable": True,
            "problems": [],
        }

    def get_volume_state(self) -> tuple[int, bool]:
        return self._volume, self._muted

    def set_volume(self, level: int) -> tuple[int, bool]:
        self._volume = max(0, min(100, level))
        if self._volume > 0:
            self._muted = False
        return self._volume, self._muted

    def adjust_volume(self, delta: int) -> tuple[int, bool]:
        return self.set_volume(self._volume + delta)

    def toggle_mute(self) -> tuple[int, bool]:
        self._muted = not self._muted
        return self._volume, self._muted

    def get_mic_state(self) -> tuple[int, bool]:
        return (0 if self._mic_muted else self._mic_volume), self._mic_muted

    def set_mic_volume(self, level: int) -> tuple[int, bool]:
        self._mic_volume = max(0, min(100, level))
        if self._mic_volume > 0:
            self._last_mic_volume = self._mic_volume
            self._mic_muted = False
        else:
            self._mic_muted = True
        return self._mic_volume, self._mic_muted

    def adjust_mic_volume(self, delta: int) -> tuple[int, bool]:
        base = self._last_mic_volume if self._mic_muted else self._mic_volume
        return self.set_mic_volume(base + delta)

    def toggle_mic_mute(self) -> tuple[int, bool]:
        if not self._mic_muted and self._mic_volume > 0:
            self._last_mic_volume = self._mic_volume
            self._mic_muted = True
            return 0, True
        restored = max(10, self._last_mic_volume)
        self._mic_volume = restored
        self._mic_muted = False
        return restored, False

    def list_audio_outputs(self) -> list[dict[str, Any]]:
        return [{"id": "default", "name": "System Default", "isDefault": True}]

    def set_audio_output(self, output_id: str) -> bool:
        return output_id == "default"

    def list_audio_inputs(self) -> list[dict[str, Any]]:
        return [{"id": "default", "name": "System Default", "isDefault": True}]

    def set_audio_input(self, input_id: str) -> bool:
        return input_id == "default"

    def get_brightness(self) -> int:
        return self._brightness

    def set_brightness(self, level: int) -> int:
        self._brightness = max(0, min(100, level))
        return self._brightness

    def adjust_brightness(self, delta: int) -> int:
        return self.set_brightness(self._brightness + delta)

    def media_control(self, action: str) -> bool:
        key_map = {
            "play-pause": "media_play_pause",
            "next": "media_next",
            "prev": "media_previous",
            "fullscreen": "f",
        }
        target = key_map.get(action)
        if not target:
            return False
        try:
            self.key_press(target, [])
            return True
        except Exception as exc:
            logger.debug("Media control %s failed: %s", action, exc)
            return False

    def take_screenshot(self) -> ScreenshotResult:
        try:
            import mss  # type: ignore
            from PIL import Image  # type: ignore

            with mss.mss() as sct:
                monitor = sct.monitors[1] if len(sct.monitors) > 1 else sct.monitors[0]
                shot = sct.grab(monitor)
                img = Image.frombytes("RGB", shot.size, shot.rgb)
                buf = io.BytesIO()
                img.save(buf, format="JPEG", quality=78, optimize=True)
                return ScreenshotResult(
                    format="jpeg",
                    width=img.width,
                    height=img.height,
                    data=buf.getvalue(),
                )
        except Exception as exc:
            logger.debug("Screenshot capture fallback: %s", exc)
            return ScreenshotResult(format="png", width=1, height=1, data=FALLBACK_PNG_BYTES)

    def list_running_apps(self) -> list[dict[str, Any]]:
        apps: list[dict[str, Any]] = []
        try:
            import psutil  # type: ignore

            seen: set[str] = set()
            for proc in psutil.process_iter(["pid", "name"]):
                name = proc.info.get("name") or ""
                if not name or name in seen:
                    continue
                seen.add(name)
                apps.append(
                    {
                        "id": str(proc.info["pid"]),
                        "name": name,
                        "icon": "app",
                        "iconImage": None,
                    }
                )
                if len(apps) >= 40:
                    break
        except Exception:
            pass
        return apps

    def close_app(self, app_id: str, force: bool = False) -> tuple[bool, str]:
        try:
            import psutil  # type: ignore

            pid = int(app_id)
            proc = psutil.Process(pid)
            if force:
                proc.kill()
            else:
                proc.terminate()
                try:
                    proc.wait(timeout=3.0)
                except psutil.TimeoutExpired:
                    return False, "Application did not close"
            return True, "Application closed"
        except Exception as exc:
            return False, str(exc)

    def open_url(self, url: str) -> bool:
        return bool(webbrowser.open(url))

    def set_clipboard(self, text: str) -> bool:
        return False

    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        return "", False

    def mouse_move(self, dx: int, dy: int) -> None:
        try:
            from pynput.mouse import Controller  # type: ignore

            Controller().move(dx, dy)
        except Exception as exc:
            logger.debug("mouse_move unavailable: %s", exc)

    def mouse_scroll(self, dx: int, dy: int) -> None:
        try:
            from pynput.mouse import Controller  # type: ignore

            Controller().scroll(dx, dy)
        except Exception as exc:
            logger.debug("mouse_scroll unavailable: %s", exc)

    def mouse_click(self, button: str, count: int) -> None:
        try:
            from pynput.mouse import Button, Controller  # type: ignore

            btn = Button.right if button == "right" else Button.left
            Controller().click(btn, max(1, min(count, 3)))
        except Exception as exc:
            logger.debug("mouse_click unavailable: %s", exc)

    def mouse_drag(self, state: str) -> None:
        try:
            from pynput.mouse import Button, Controller  # type: ignore

            ctrl = Controller()
            if state == "down":
                ctrl.press(Button.left)
            else:
                ctrl.release(Button.left)
        except Exception as exc:
            logger.debug("mouse_drag unavailable: %s", exc)

    def key_text(self, text: str) -> None:
        try:
            from pynput.keyboard import Controller  # type: ignore

            Controller().type(text)
        except Exception as exc:
            logger.debug("key_text unavailable: %s", exc)

    def key_press(self, key: str, mods: list[str]) -> None:
        try:
            from pynput.keyboard import Controller, Key  # type: ignore

            ctrl = Controller()
            special_map = {
                "escape": Key.esc,
                "esc": Key.esc,
                "tab": Key.tab,
                "enter": Key.enter,
                "return": Key.enter,
                "backspace": Key.backspace,
                "delete": Key.delete,
                "space": Key.space,
                "up": Key.up,
                "down": Key.down,
                "left": Key.left,
                "right": Key.right,
                "media_play_pause": Key.media_play_pause,
                "media_next": Key.media_next,
                "media_previous": Key.media_previous,
            }
            mod_map = {
                "ctrl": Key.ctrl,
                "control": Key.ctrl,
                "alt": Key.alt,
                "option": Key.alt,
                "shift": Key.shift,
                "cmd": Key.cmd,
                "meta": Key.cmd,
                "win": Key.cmd,
            }
            pressed_mods = [mod_map[m.lower()] for m in mods if m.lower() in mod_map]
            target: Any = special_map.get(key.lower(), key)
            for mod in pressed_mods:
                ctrl.press(mod)
            try:
                ctrl.press(target)
                ctrl.release(target)
            finally:
                for mod in reversed(pressed_mods):
                    ctrl.release(mod)
        except Exception as exc:
            logger.debug("key_press unavailable: %s", exc)


class MacOSSystemBackend(BaseRealSystemBackend):
    """macOS backend using osascript / pmset / pbcopy / pbpaste."""

    def power_action(self, action: str) -> tuple[bool, str]:
        commands: dict[str, list[str]] = {
            "shutdown": ["osascript", "-e", 'tell app "System Events" to shut down'],
            "restart": ["osascript", "-e", 'tell app "System Events" to restart'],
            "sleep": ["pmset", "sleepnow"],
            "hibernate": ["pmset", "sleepnow"],
            "lock": ["osascript", "-e", 'tell app "System Events" to keystroke "q" using {command down, control down}'],
            "display-off": ["pmset", "displaysleepnow"],
            "display-on": ["caffeinate", "-u", "-t", "2"],
        }
        cmd = commands.get(action)
        if not cmd:
            return False, f"Unknown power action: {action}"
        try:
            subprocess.Popen(cmd)
            return True, f"Executed {action}"
        except OSError as exc:
            return False, str(exc)

    def set_volume(self, level: int) -> tuple[int, bool]:
        vol, muted = super().set_volume(level)
        try:
            subprocess.run(
                ["osascript", "-e", f"set volume output volume {vol}"],
                check=False,
                timeout=3,
            )
        except OSError:
            pass
        return vol, muted

    def toggle_mute(self) -> tuple[int, bool]:
        vol, muted = super().toggle_mute()
        flag = "true" if muted else "false"
        try:
            subprocess.run(
                ["osascript", "-e", f"set volume output muted {flag}"],
                check=False,
                timeout=3,
            )
        except OSError:
            pass
        return vol, muted

    def get_mic_state(self) -> tuple[int, bool]:
        try:
            out = subprocess.check_output(
                ["osascript", "-e", "((input volume of (get volume settings)) as string)"],
                timeout=3,
            ).decode("utf-8", errors="replace").strip()
            vol = max(0, min(100, int(out)))
            if vol > 0:
                self._last_mic_volume = vol
                self._mic_volume = vol
                self._mic_muted = False
                return vol, False
            self._mic_muted = True
            return 0, True
        except Exception:
            return super().get_mic_state()

    def set_mic_volume(self, level: int) -> tuple[int, bool]:
        vol, muted = super().set_mic_volume(level)
        try:
            subprocess.run(
                ["osascript", "-e", f"set volume input volume {vol}"],
                check=False,
                timeout=3,
            )
        except OSError:
            pass
        return vol, muted

    def toggle_mic_mute(self) -> tuple[int, bool]:
        cur_vol, cur_muted = self.get_mic_state()
        if not cur_muted and cur_vol > 0:
            self._last_mic_volume = cur_vol
            return self.set_mic_volume(0)
        return self.set_mic_volume(max(10, self._last_mic_volume))

    def set_clipboard(self, text: str) -> bool:
        try:
            subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True, timeout=3)
            return True
        except Exception:
            return False

    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        try:
            out = subprocess.check_output(["pbpaste"], timeout=3).decode("utf-8", errors="replace")
            if len(out) > max_chars:
                return out[:max_chars], True
            return out, False
        except Exception:
            return "", False


class WindowsSystemBackend(BaseRealSystemBackend):
    """Windows backend using shutdown.exe / rundll32 / PowerShell."""

    def power_action(self, action: str) -> tuple[bool, str]:
        commands: dict[str, list[str]] = {
            "shutdown": ["shutdown", "/s", "/t", "0"],
            "restart": ["shutdown", "/r", "/t", "0"],
            "sleep": ["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"],
            "hibernate": ["shutdown", "/h"],
            "lock": ["rundll32.exe", "user32.dll,LockWorkStation"],
            "display-off": [
                "powershell",
                "-NoProfile",
                "-Command",
                "(Add-Type '[DllImport(\"user32.dll\")]public static extern int SendMessage(int h,int m,int w,int l);' -Name a -Pas)::SendMessage(-1,0x0112,0xF170,2)",
            ],
            "display-on": [
                "powershell",
                "-NoProfile",
                "-Command",
                "(Add-Type '[DllImport(\"user32.dll\")]public static extern int SendMessage(int h,int m,int w,int l);' -Name a -Pas)::SendMessage(-1,0x0112,0xF170,-1)",
            ],
        }
        cmd = commands.get(action)
        if not cmd:
            return False, f"Unknown power action: {action}"
        try:
            subprocess.Popen(cmd)
            return True, f"Executed {action}"
        except OSError as exc:
            return False, str(exc)

    def set_clipboard(self, text: str) -> bool:
        try:
            subprocess.run(["clip"], input=text.encode("utf-16-le"), check=True, timeout=3)
            return True
        except Exception:
            return False

    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        try:
            out = subprocess.check_output(
                ["powershell", "-NoProfile", "-Command", "Get-Clipboard"],
                timeout=3,
            ).decode("utf-8", errors="replace")
            if len(out) > max_chars:
                return out[:max_chars], True
            return out, False
        except Exception:
            return "", False


class LinuxSystemBackend(BaseRealSystemBackend):
    """Linux backend using systemctl / loginctl / pactl / xclip."""

    def power_action(self, action: str) -> tuple[bool, str]:
        commands: dict[str, list[str]] = {
            "shutdown": ["systemctl", "poweroff"],
            "restart": ["systemctl", "reboot"],
            "sleep": ["systemctl", "suspend"],
            "hibernate": ["systemctl", "hibernate"],
            "lock": ["loginctl", "lock-session"],
            "display-off": ["xset", "dpms", "force", "off"],
            "display-on": ["xset", "dpms", "force", "on"],
        }
        cmd = commands.get(action)
        if not cmd or not shutil.which(cmd[0]):
            return False, f"Command unavailable for action {action}"
        try:
            subprocess.Popen(cmd)
            return True, f"Executed {action}"
        except OSError as exc:
            return False, str(exc)

    def set_volume(self, level: int) -> tuple[int, bool]:
        vol, muted = super().set_volume(level)
        if shutil.which("pactl"):
            subprocess.run(
                ["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{vol}%"],
                check=False,
                timeout=3,
            )
        return vol, muted

    def toggle_mute(self) -> tuple[int, bool]:
        vol, muted = super().toggle_mute()
        if shutil.which("pactl"):
            subprocess.run(
                ["pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" if muted else "0"],
                check=False,
                timeout=3,
            )
        return vol, muted

    def set_clipboard(self, text: str) -> bool:
        if shutil.which("xclip"):
            subprocess.run(["xclip", "-selection", "clipboard"], input=text.encode("utf-8"), check=False, timeout=3)
            return True
        if shutil.which("wl-copy"):
            subprocess.run(["wl-copy"], input=text.encode("utf-8"), check=False, timeout=3)
            return True
        return False

    def get_clipboard(self, max_chars: int = 65536) -> tuple[str, bool]:
        for cmd in (["xclip", "-selection", "clipboard", "-o"], ["wl-paste"]):
            if shutil.which(cmd[0]):
                try:
                    out = subprocess.check_output(cmd, timeout=3).decode("utf-8", errors="replace")
                    if len(out) > max_chars:
                        return out[:max_chars], True
                    return out, False
                except Exception:
                    pass
        return "", False


def create_system_backend(*, mock: bool = False) -> SystemBackend:
    """Create the appropriate OS backend for the current platform."""
    if mock or os.environ.get("WAKEPC_AGENT_MOCK") == "1":
        return MockSystemBackend()
    sys_name = platform.system().lower()
    if sys_name == "darwin":
        return MacOSSystemBackend()
    if sys_name == "windows":
        return WindowsSystemBackend()
    return LinuxSystemBackend()
