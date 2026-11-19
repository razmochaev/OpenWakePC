"""Bonjour / mDNS service advertiser (`_wakepc._tcp.local.`) for automatic LAN discovery."""

from __future__ import annotations

import logging
import socket
from typing import Any

from .config import AGENT_VERSION, AgentConfig

logger = logging.getLogger("wakepc.agent.discovery")


class BonjourAdvertiser:
    """Publishes `_wakepc._tcp.local.` with TXT metadata when `zeroconf` is installed."""

    SERVICE_TYPE = "_wakepc._tcp.local."

    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self._zeroconf: Any = None
        self._info: Any = None

    def start(self) -> bool:
        if not self.config.enable_bonjour:
            return False
        try:
            from zeroconf import ServiceInfo, Zeroconf  # type: ignore

            safe_name = self.config.name.replace(".", "-")[:48]
            service_name = f"{safe_name}.{self.SERVICE_TYPE}"
            props = {
                "mac": self.config.mac,
                "bcast": self.config.broadcast,
                "name": self.config.name,
                "type": self.config.device_type,
                "deviceId": self.config.device_id,
                "apiPort": str(self.config.api_port),
                "wolPort": str(self.config.wol_port),
                "version": AGENT_VERSION,
            }
            self._info = ServiceInfo(
                type_=self.SERVICE_TYPE,
                name=service_name,
                addresses=[socket.inet_aton(self.config.ip)],
                port=self.config.api_port,
                properties=props,
            )
            self._zeroconf = Zeroconf()
            self._zeroconf.register_service(self._info)
            logger.info("Bonjour service advertised: %s on %s:%d", service_name, self.config.ip, self.config.api_port)
            return True
        except Exception as exc:
            logger.info("Bonjour advertising skipped (optional zeroconf unavailable): %s", exc)
            return False

    def stop(self) -> None:
        if self._zeroconf is not None:
            try:
                if self._info is not None:
                    self._zeroconf.unregister_service(self._info)
                self._zeroconf.close()
            except Exception:
                pass
            self._zeroconf = None
            self._info = None
