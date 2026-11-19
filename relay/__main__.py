"""CLI entry point for the Open Wake PC self-hosted E2EE Relay Server."""

from __future__ import annotations

import argparse
import logging

from aiohttp import web

from .config import RelayConfig
from .server import create_relay_app


def parse_args() -> argparse.Namespace:
    env_cfg = RelayConfig.from_env()
    parser = argparse.ArgumentParser(
        prog="wakepc-relay",
        description="OpenWakePC self-hosted zero-knowledge E2EE Relay Server by razmochaev",
    )
    parser.add_argument("--host", default=env_cfg.host, help="Bind host (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=env_cfg.port, help="Bind port (default: 8787)")
    parser.add_argument(
        "--public-url",
        default=env_cfg.public_url,
        help="Public HTTPS URL advertised in /relay.json",
    )
    parser.add_argument(
        "--push-store",
        default=env_cfg.push_storage_path,
        help="Optional path to JSON file for persisting push registrations",
    )
    parser.add_argument("--log-level", default="INFO", help="Logging level (default: INFO)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    cfg = RelayConfig(
        host=args.host,
        port=args.port,
        public_url=args.public_url.rstrip("/"),
        push_storage_path=args.push_store,
    )
    app = create_relay_app(cfg)
    web.run_app(app, host=cfg.host, port=cfg.port)


if __name__ == "__main__":
    main()
