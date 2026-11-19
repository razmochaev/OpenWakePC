"""Scheduled power actions and CPU/network idle automation for the Desktop Agent."""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Awaitable, Callable

from .backends import SystemBackend

logger = logging.getLogger("wakepc.agent.scheduler")

IDLE_CPU_THRESHOLD = 10.0  # %
IDLE_NET_BYTES_PER_TICK = 50 * 1024  # 50 KB per tick


class ActionScheduler:
    """Manages countdown power schedules, 'when PC finishes' idle-actions, and idle-notify."""

    def __init__(
        self,
        backend: SystemBackend,
        on_idle_notify: Callable[[int], Awaitable[None]] | None = None,
        tick_interval_sec: float = 5.0,
    ) -> None:
        self.backend = backend
        self.on_idle_notify = on_idle_notify
        self.tick_interval_sec = tick_interval_sec

        # Timed countdown action
        self.scheduled_action: str | None = None
        self.scheduled_at: float | None = None

        # "When PC finishes" idle action
        self.idle_action: str | None = None  # "shutdown" | "sleep" | None
        self.idle_minutes: int = 10
        self.idle_streak_seconds: int = 0

        # Idle push notification threshold (0 = off, 1, 2, 4 hours)
        self.idle_notify_hours: int = 0
        self._idle_notified_for_streak: bool = False
        self._last_net_bytes: int = backend.get_network_bytes()
        self._task: asyncio.Task[None] | None = None

    def start(self) -> None:
        if self._task is None or self._task.done():
            self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self._task is not None and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        self._task = None

    def schedule_power(self, action: str, minutes: int) -> dict[str, Any]:
        """Schedule shutdown, restart, or sleep after `minutes`."""
        if action not in {"shutdown", "restart", "sleep"}:
            raise ValueError(f"Unsupported scheduled action: {action}")
        if minutes < 1 or minutes > 1440:
            raise ValueError("Minutes must be between 1 and 1440")
        self.scheduled_action = action
        self.scheduled_at = time.time() + minutes * 60
        return self.get_status()

    def cancel_scheduled(self) -> dict[str, Any]:
        """Cancel any active timed schedule and idle action."""
        self.scheduled_action = None
        self.scheduled_at = None
        self.idle_action = None
        self.idle_streak_seconds = 0
        return self.get_status()

    def set_idle_action(self, action: str | None, minutes: int = 10) -> dict[str, Any]:
        """Enable or cancel 'when PC finishes' idle automation."""
        if action in {None, "", "off", "cancel", "none"}:
            self.idle_action = None
            self.idle_streak_seconds = 0
        elif action in {"shutdown", "sleep"}:
            self.idle_action = action
            self.idle_minutes = max(1, min(minutes, 240))
            self.idle_streak_seconds = 0
        else:
            raise ValueError(f"Unsupported idle action: {action}")
        return self.get_status()

    def set_idle_notify(self, hours: int) -> dict[str, Any]:
        """Configure idle push notification threshold (0=off, 1, 2, or 4 hours)."""
        if hours not in {0, 1, 2, 4}:
            raise ValueError("idle_notify hours must be one of 0, 1, 2, 4")
        self.idle_notify_hours = hours
        self._idle_notified_for_streak = False
        return self.get_status()

    def get_status(self) -> dict[str, Any]:
        now = time.time()
        has_scheduled = self.scheduled_action is not None and self.scheduled_at is not None
        remaining = max(0, int(self.scheduled_at - now)) if (has_scheduled and self.scheduled_at) else 0
        return {
            "hasScheduled": has_scheduled,
            "action": self.scheduled_action,
            "remainingSeconds": remaining,
            "scheduledAt": int(self.scheduled_at) if self.scheduled_at else None,
            "idleAction": self.idle_action,
            "idleMinutes": self.idle_minutes,
            "idleStreakSeconds": self.idle_streak_seconds,
            "idleNotifyHours": self.idle_notify_hours,
        }

    async def tick(self) -> None:
        """Single scheduler tick (also callable directly in tests)."""
        now = time.time()

        # 1. Check timed schedule
        if self.scheduled_action and self.scheduled_at and now >= self.scheduled_at:
            action = self.scheduled_action
            self.scheduled_action = None
            self.scheduled_at = None
            logger.info("Executing scheduled action: %s", action)
            self.backend.power_action(action)
            return

        # 2. Check idle state when either idle_action or idle_notify is enabled
        if self.idle_action or self.idle_notify_hours > 0:
            telemetry = self.backend.get_telemetry()
            cpu = float(telemetry.get("cpuLoad", 0.0))
            cur_net = self.backend.get_network_bytes()
            net_delta = max(0, cur_net - self._last_net_bytes)
            self._last_net_bytes = cur_net

            if cpu < IDLE_CPU_THRESHOLD and net_delta < IDLE_NET_BYTES_PER_TICK:
                self.idle_streak_seconds += int(self.tick_interval_sec)
            else:
                self.idle_streak_seconds = 0
                self._idle_notified_for_streak = False

            if self.idle_action and self.idle_streak_seconds >= self.idle_minutes * 60:
                action = self.idle_action
                self.idle_action = None
                self.idle_streak_seconds = 0
                logger.info("Executing idle action after streak: %s", action)
                self.backend.power_action(action)
                return

            if (
                self.idle_notify_hours > 0
                and not self._idle_notified_for_streak
                and self.idle_streak_seconds >= self.idle_notify_hours * 3600
            ):
                self._idle_notified_for_streak = True
                if self.on_idle_notify is not None:
                    await self.on_idle_notify(self.idle_notify_hours)

    async def _loop(self) -> None:
        while True:
            await asyncio.sleep(self.tick_interval_sec)
            try:
                await self.tick()
            except Exception as exc:
                logger.warning("Scheduler tick error: %s", exc)
