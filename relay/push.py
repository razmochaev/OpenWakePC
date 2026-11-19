"""Push notification registration store and pluggable APNs dispatcher for the relay."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Protocol

logger = logging.getLogger("wakepc.relay.push")


@dataclass(slots=True)
class PushSubscription:
    """Registered APNs subscription for a deviceId room."""

    device_id: str
    claim: str
    token: str
    name: str
    env: str  # "production" | "development"
    enable: bool = True
    caps: list[str] = field(default_factory=list)
    updated_at: float = field(default_factory=time.time)


class PushNotifier(Protocol):
    """Protocol for sending APNs notifications (pluggable for self-hosters)."""

    async def notify(
        self,
        subscription: PushSubscription,
        event: str,
        payload: dict[str, Any],
    ) -> bool:
        ...


class LoggingPushNotifier:
    """Default zero-dependency notifier that records events locally without Apple credentials."""

    def __init__(self) -> None:
        self.sent_events: list[dict[str, Any]] = []

    async def notify(
        self,
        subscription: PushSubscription,
        event: str,
        payload: dict[str, Any],
    ) -> bool:
        record = {
            "device_id": subscription.device_id,
            "name": subscription.name,
            "env": subscription.env,
            "event": event,
            "payload": payload,
            "ts": time.time(),
        }
        self.sent_events.append(record)
        logger.info(
            "Push event=%s device=%s pc=%s env=%s",
            event,
            subscription.device_id,
            subscription.name,
            subscription.env,
        )
        return True


class PushRegistry:
    """In-memory (optionally JSON-persisted) registry of push subscriptions keyed by device_id."""

    def __init__(self, storage_path: str = "") -> None:
        self._storage_path = Path(storage_path) if storage_path else None
        # device_id -> {apns_token_hex: PushSubscription}
        self._subscriptions: dict[str, dict[str, PushSubscription]] = {}
        if self._storage_path and self._storage_path.exists():
            self._load()

    def register(self, sub: PushSubscription) -> None:
        """Add, update, or disable a push subscription."""
        room = self._subscriptions.setdefault(sub.device_id, {})
        if sub.enable:
            room[sub.token] = sub
        else:
            room.pop(sub.token, None)
            if not room:
                self._subscriptions.pop(sub.device_id, None)
        self._save()

    def get_for_device(self, device_id: str) -> list[PushSubscription]:
        """Return all enabled subscriptions for a given device_id."""
        room = self._subscriptions.get(device_id, {})
        return [sub for sub in room.values() if sub.enable]

    def get_known_claim(self, device_id: str) -> str | None:
        """Return any existing room claim stored for this device_id."""
        room = self._subscriptions.get(device_id, {})
        for sub in room.values():
            return sub.claim
        return None

    def _save(self) -> None:
        if not self._storage_path:
            return
        self._storage_path.parent.mkdir(parents=True, exist_ok=True)
        serialized = {
            dev_id: {tok: asdict(sub) for tok, sub in subs.items()}
            for dev_id, subs in self._subscriptions.items()
        }
        self._storage_path.write_text(json.dumps(serialized, indent=2), encoding="utf-8")

    def _load(self) -> None:
        if not self._storage_path:
            return
        try:
            raw = json.loads(self._storage_path.read_text(encoding="utf-8"))
            for dev_id, subs in raw.items():
                self._subscriptions[dev_id] = {
                    tok: PushSubscription(**data) for tok, data in subs.items()
                }
        except Exception as exc:
            logger.warning("Failed to load push store %s: %s", self._storage_path, exc)
