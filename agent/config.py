"""Configuration, QR URL generation, and local network identity for the Desktop Agent."""

from __future__ import annotations

import ipaddress
import json
import os
import platform
import secrets
import socket
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from common.crypto import mask_url_token, validate_token

AGENT_VERSION = "3.0.0-open"
DEFAULT_API_PORT = 8765
DEFAULT_WOL_PORT = 9
MAX_UPLOAD_BYTES = 500 * 1024 * 1024  # 500 MiB


def detect_device_type() -> str:
    """Return 'mac' on macOS, 'windows' on Windows (or 'windows' compatible default on Linux)."""
    sys_name = platform.system().lower()
    if sys_name == "darwin":
        return "mac"
    return "windows"


def detect_local_ip_and_broadcast() -> tuple[str, str]:
    """Best-effort detection of primary LAN IPv4 address and /24 broadcast address."""
    local_ip = "127.0.0.1"
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
    except OSError:
        pass
    try:
        net = ipaddress.IPv4Network(f"{local_ip}/24", strict=False)
        broadcast = str(net.broadcast_address)
    except ValueError:
        broadcast = "255.255.255.255"
    return local_ip, broadcast


def detect_mac_address() -> str:
    """Best-effort detection of host MAC address formatted as AA:BB:CC:DD:EE:FF."""
    node = uuid.getnode()
    octets = [(node >> shift) & 0xFF for shift in range(40, -1, -8)]
    return ":".join(f"{b:02X}" for b in octets)


def generate_secure_token() -> str:
    """Generate a 32-character token matching ^[A-Za-z0-9_-]{8,64}$."""
    token = secrets.token_urlsafe(24)[:32]
    assert validate_token(token)
    return token


@dataclass(slots=True)
class CustomCommandConfig:
    """User-defined custom command exposed in /commands."""

    id: str
    name: str
    command: list[str]
    icon: str = "terminal"
    closable: bool = True


@dataclass(slots=True)
class AgentConfig:
    """Persistent configuration for the Open Wake PC Desktop Agent."""

    name: str = field(default_factory=socket.gethostname)
    device_id: str = field(default_factory=lambda: str(uuid.uuid4()).lower())
    device_type: str = field(default_factory=detect_device_type)
    token: str = field(default_factory=generate_secure_token)
    mac: str = field(default_factory=detect_mac_address)
    ip: str = field(default_factory=lambda: detect_local_ip_and_broadcast()[0])
    broadcast: str = field(default_factory=lambda: detect_local_ip_and_broadcast()[1])
    bind_host: str = "0.0.0.0"
    api_port: int = DEFAULT_API_PORT
    wol_port: int = DEFAULT_WOL_PORT
    relay_url: str = ""
    relay_discovery_url: str = ""
    downloads_dir: str = field(default_factory=lambda: str(Path.home() / "Downloads"))
    enable_bonjour: bool = True
    custom_commands: list[CustomCommandConfig] = field(default_factory=list)

    def build_qr_url(self) -> str:
        """Build wakepc://config?... URL compatible with the iOS QR scanner."""
        params = {
            "mac": self.mac.upper(),
            "ip": self.ip,
            "bcast": self.broadcast,
            "wolPort": str(self.wol_port),
            "apiPort": str(self.api_port),
            "token": self.token,
            "deviceType": self.device_type,
            "deviceId": self.device_id,
        }
        return f"wakepc://config?{urlencode(params)}"

    def build_masked_qr_url(self) -> str:
        """Build QR URL with token redacted for safe logging."""
        return mask_url_token(self.build_qr_url())

    @classmethod
    def default_config_path(cls) -> Path:
        base = os.environ.get("XDG_CONFIG_HOME")
        if base:
            return Path(base) / "open-wakepc" / "agent.json"
        return Path.home() / ".config" / "open-wakepc" / "agent.json"

    @classmethod
    def load_or_create(cls, path: Path | None = None) -> "AgentConfig":
        target = path or cls.default_config_path()
        if target.exists():
            raw = json.loads(target.read_text(encoding="utf-8"))
            cmds = [CustomCommandConfig(**c) for c in raw.pop("custom_commands", [])]
            cfg = cls(**raw, custom_commands=cmds)
            if not validate_token(cfg.token):
                cfg.token = generate_secure_token()
                cfg.save(target)
            return cfg
        cfg = cls()
        cfg.save(target)
        return cfg

    def save(self, path: Path | None = None) -> None:
        target = path or self.default_config_path()
        target.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, Any] = asdict(self)
        target.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass
