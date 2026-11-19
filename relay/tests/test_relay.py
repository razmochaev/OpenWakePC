"""Unit and integration tests for common.crypto and the E2EE Relay Server."""

from __future__ import annotations

import asyncio
import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from common.crypto import (
    RelayCryptoError,
    build_wol_magic_packet,
    compute_room_claim,
    decode_command_payload,
    derive_key,
    encode_command_payload,
    mask_url_token,
    open_envelope,
    seal_envelope,
    validate_mac,
    validate_token,
    verify_room_claim,
)
from relay.config import RelayConfig
from relay.push import LoggingPushNotifier
from relay.server import create_relay_app


def test_crypto_roundtrip_and_aad_binding() -> None:
    token = "SecretToken_12345678"
    device_id = "pc-home-01"
    plaintext = encode_command_payload("/shutdown-in", {"minutes": "30"})
    assert json.loads(plaintext.decode()) == {"path": "/shutdown-in", "query": {"minutes": "30"}}

    env = seal_envelope(plaintext, token, device_id)
    assert env["v"] == 1
    assert set(env.keys()) == {"v", "id", "ts", "n", "c"}

    decrypted = open_envelope(env, token, device_id)
    path, query = decode_command_payload(decrypted)
    assert path == "/shutdown-in"
    assert query == {"minutes": "30"}

    # Wrong token must fail GCM tag
    with pytest.raises(RelayCryptoError):
        open_envelope(env, "WrongToken_12345678", device_id)

    # Wrong device_id changes both HKDF info and AAD
    with pytest.raises(RelayCryptoError):
        open_envelope(env, token, "pc-other-02")


def test_command_payload_omits_empty_query() -> None:
    raw = encode_command_payload("/status", {})
    assert json.loads(raw.decode()) == {"path": "/status"}
    assert decode_command_payload(raw) == ("/status", {})


def test_room_claim_and_validators() -> None:
    token = "ValidToken_abcDEF99"
    device_id = "dev-uuid-1234"
    claim = compute_room_claim(token, device_id)
    assert verify_room_claim(claim, claim)
    assert not verify_room_claim(claim, compute_room_claim("OtherToken_12345", device_id))
    assert len(derive_key(token, device_id)) == 32

    assert validate_mac("aa:bb:cc:dd:ee:ff")
    assert validate_mac("AA:BB:CC:DD:EE:FF")
    assert not validate_mac("AA-BB-CC-DD-EE-FF")
    assert not validate_mac("invalid")

    assert validate_token("Abcdef_1")
    assert not validate_token("short")
    assert not validate_token("bad space token")

    masked = mask_url_token("wakepc://config?mac=AA:BB:CC:DD:EE:FF&token=mySecret123&apiPort=8765")
    assert "mySecret123" not in masked
    assert "token=***" in masked

    magic = build_wol_magic_packet("AA:BB:CC:DD:EE:FF")
    assert len(magic) == 102
    assert magic[:6] == b"\xff" * 6
    assert magic[6:12] == bytes.fromhex("AABBCCDDEEFF")


@pytest.mark.asyncio
async def test_relay_end_to_end_forwarding_and_push() -> None:
    notifier = LoggingPushNotifier()
    app = create_relay_app(
        RelayConfig(public_url="https://relay.selfhosted.local"),
        push_notifier=notifier,
    )
    token = "MySuperSecretToken_99"
    device_id = "gaming-rig-01"
    claim = compute_room_claim(token, device_id)

    async with TestClient(TestServer(app)) as client:
        # Discovery & health
        resp = await client.get("/relay.json")
        assert resp.status == 200
        assert (await resp.json()) == {"relay_url": "https://relay.selfhosted.local"}

        health = await client.get("/health")
        assert (await health.json()) == {"status": "ok", "connected_agents": 0}

        # Register push notification before agent connects
        push_resp = await client.post(
            f"/push/{device_id}",
            json={
                "claim": claim,
                "token": "0123456789abcdef0123456789abcdef",
                "name": "Gaming PC",
                "env": "production",
                "enable": True,
                "caps": ["presence", "idle"],
            },
        )
        assert push_resp.status == 200
        assert (await push_resp.json())["success"] is True

        # Wrong claim rejected for push
        bad_push = await client.post(
            f"/push/{device_id}",
            json={
                "claim": compute_room_claim("AnotherSecret_999", device_id),
                "token": "0123456789abcdef0123456789abcdef",
                "name": "Hijack",
                "env": "production",
                "enable": True,
                "caps": [],
            },
        )
        assert bad_push.status == 403

        # Sending while agent offline -> 502
        offline_env = seal_envelope(encode_command_payload("/status"), token, device_id)
        offline_resp = await client.post(f"/send/{device_id}?timeout=5", json=offline_env)
        assert offline_resp.status == 502

        # Connect agent over WebSocket
        async with client.ws_connect(f"/ws/agent/{device_id}") as ws:
            await ws.send_json({"type": "auth", "claim": claim})
            auth_ok = await ws.receive_json()
            assert auth_ok == {"type": "auth_ok", "device_id": device_id}

            # Presence online push was dispatched
            assert any(e["event"] == "pc_online" for e in notifier.sent_events)

            async def agent_loop() -> None:
                msg = await ws.receive_json()
                assert msg["type"] == "request"
                req_plain = open_envelope(msg["envelope"], token, device_id)
                path, query = decode_command_payload(req_plain)
                assert path == "/volume-set/42"
                assert query == {}
                reply_bytes = json.dumps({"success": True, "data": {"volume": 42}}).encode()
                resp_env = seal_envelope(reply_bytes, token, device_id, envelope_id=msg["id"])
                await ws.send_json({"type": "response", "id": msg["id"], "envelope": resp_env})

            agent_task = asyncio.create_task(agent_loop())

            req_env = seal_envelope(encode_command_payload("/volume-set/42"), token, device_id)
            send_resp = await client.post(f"/send/{device_id}?timeout=5", json=req_env)
            assert send_resp.status == 200
            resp_env = await send_resp.json()
            plain = open_envelope(resp_env, token, device_id)
            assert json.loads(plain.decode()) == {"success": True, "data": {"volume": 42}}
            await agent_task

            # Agent sends idle event -> relay dispatches push
            await ws.send_json({"type": "event", "event": "pc_idle", "idle_hours": 2})
            await asyncio.sleep(0.05)
            assert any(e["event"] == "pc_idle" for e in notifier.sent_events)
