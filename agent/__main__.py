"""CLI entry point for the Open Wake PC Desktop Agent."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path

from aiohttp import web

from .backends import create_system_backend
from .config import AGENT_VERSION, AgentConfig
from .server import create_agent_app


def _print_qr_to_terminal(url: str) -> None:
    try:
        import qrcode  # type: ignore

        qr = qrcode.QRCode(border=2)
        qr.add_data(url)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except Exception:
        print("(Install optional `qrcode` package to render QR code in terminal)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="wakepc-agent",
        description="OpenWakePC Desktop Agent by razmochaev (Windows / macOS / Linux)",
    )
    parser.add_argument("--config", type=Path, default=None, help="Path to agent.json")
    parser.add_argument("--port", type=int, default=None, help="Override HTTP API port (default: 8765)")
    parser.add_argument("--relay-url", default=None, help="Self-hosted E2EE Relay base URL")
    parser.add_argument("--relay-discovery-url", default=None, help="Optional relay.json discovery URL")
    parser.add_argument("--no-bonjour", action="store_true", help="Disable Bonjour (_wakepc._tcp) advertising")
    parser.add_argument("--mock", action="store_true", help="Run with in-memory mock OS backend")
    parser.add_argument("--show-qr", action="store_true", help="Print pairing QR URL and exit")
    parser.add_argument("--log-level", default="INFO", help="Logging level (default: INFO)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    cfg = AgentConfig.load_or_create(args.config)
    if args.port is not None:
        cfg.api_port = args.port
    if args.relay_url is not None:
        cfg.relay_url = args.relay_url.rstrip("/")
    if args.relay_discovery_url is not None:
        cfg.relay_discovery_url = args.relay_discovery_url
    if args.no_bonjour:
        cfg.enable_bonjour = False

    qr_url = cfg.build_qr_url()
    print(f"\nOpen Wake PC Agent v{AGENT_VERSION}")
    print(f"  Name:       {cfg.name} ({cfg.device_type})")
    print(f"  LAN API:    http://{cfg.ip}:{cfg.api_port}")
    print(f"  MAC:        {cfg.mac} (broadcast: {cfg.broadcast})")
    print(f"  Device ID:  {cfg.device_id}")
    print(f"  Relay:      {cfg.relay_url or cfg.relay_discovery_url or 'LAN-only'}")
    print(f"  QR Link:    {cfg.build_masked_qr_url()}\n")
    _print_qr_to_terminal(qr_url)

    if args.show_qr:
        return

    backend = create_system_backend(mock=args.mock)
    app = create_agent_app(cfg, backend=backend)
    web.run_app(app, host=cfg.bind_host, port=cfg.api_port)


if __name__ == "__main__":
    main()
