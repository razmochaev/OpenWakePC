"""Configuration for the Open Wake PC self-hosted E2EE relay server."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(slots=True)
class RelayConfig:
    """Runtime settings for the E2EE relay server."""

    host: str = "0.0.0.0"
    port: int = 8787
    public_url: str = ""
    default_timeout_sec: float = 15.0
    max_timeout_sec: float = 60.0
    max_body_bytes: int = 4 * 1024 * 1024  # 4 MiB (covers chunked screenshots & responses)
    heartbeat_interval_sec: float = 30.0
    push_storage_path: str = ""  # Optional JSON persistence path for push registrations

    @classmethod
    def from_env(cls) -> "RelayConfig":
        """Load configuration from environment variables with safe defaults."""
        return cls(
            host=os.environ.get("WAKEPC_RELAY_HOST", "0.0.0.0"),
            port=int(os.environ.get("WAKEPC_RELAY_PORT", "8787")),
            public_url=os.environ.get("WAKEPC_RELAY_PUBLIC_URL", "").rstrip("/"),
            default_timeout_sec=float(os.environ.get("WAKEPC_RELAY_DEFAULT_TIMEOUT", "15")),
            max_timeout_sec=float(os.environ.get("WAKEPC_RELAY_MAX_TIMEOUT", "60")),
            max_body_bytes=int(os.environ.get("WAKEPC_RELAY_MAX_BODY_BYTES", str(4 * 1024 * 1024))),
            heartbeat_interval_sec=float(os.environ.get("WAKEPC_RELAY_HEARTBEAT", "30")),
            push_storage_path=os.environ.get("WAKEPC_RELAY_PUSH_STORE", ""),
        )
