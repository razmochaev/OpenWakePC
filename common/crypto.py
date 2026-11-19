"""
Exact implementation of the Wake PC E2EE relay cryptographic protocol (`wakepc-relay-v1`),
validation helpers, and Wake-on-LAN packet sender.

Protocol specification (matches Swift CryptoKit implementation 1:1):
- Key derivation: HKDF-SHA256(ikm=token.utf8, salt="wakepc-relay-v1", info=deviceId.utf8, length=32)
- Room claim:     Base64(HMAC-SHA256(key=derivedKey, msg="room-claim"))
- AAD:            "<deviceId>:v1" (UTF-8)
- Encryption:     AES-256-GCM(key=derivedKey, nonce=12 random bytes, plaintext, aad)
- Envelope JSON:  {"v": 1, "id": "<uuid-lower>", "ts": <unix_sec>, "n": "<b64 nonce>", "c": "<b64 ct||tag>"}
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import socket
import time
import uuid
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

RELAY_PROTOCOL_VERSION = 1
RELAY_HKDF_SALT = b"wakepc-relay-v1"
RELAY_ROOM_CLAIM_LABEL = b"room-claim"
AES_GCM_NONCE_BYTES = 12
AES_GCM_TAG_BYTES = 16
DERIVED_KEY_BYTES = 32

MAC_REGEX = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
TOKEN_REGEX = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
TOKEN_URL_MASK_REGEX = re.compile(r"token=[^&]+")


class RelayCryptoError(ValueError):
    """Raised when an E2EE envelope is malformed or fails authentication."""


def derive_key(token: str, device_id: str) -> bytes:
    """Derive a 32-byte AES-256 symmetric key via HKDF-SHA256."""
    if not token:
        raise RelayCryptoError("Token must not be empty")
    if not device_id:
        raise RelayCryptoError("Device ID must not be empty")
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=DERIVED_KEY_BYTES,
        salt=RELAY_HKDF_SALT,
        info=device_id.encode("utf-8"),
    )
    return hkdf.derive(token.encode("utf-8"))


def compute_room_claim(token: str, device_id: str) -> str:
    """Compute Base64(HMAC-SHA256(derivedKey, 'room-claim'))."""
    key = derive_key(token, device_id)
    digest = hmac.new(key, RELAY_ROOM_CLAIM_LABEL, hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


def compute_claim_proof(token: str, device_id: str, nonce: str) -> str:
    """Compute Base64(HMAC-SHA256(claimBytes, nonceBytes)) for zero-knowledge relay challenge-response."""
    key = derive_key(token, device_id)
    claim_bytes = hmac.new(key, RELAY_ROOM_CLAIM_LABEL, hashlib.sha256).digest()
    try:
        nonce_bytes = base64.b64decode(nonce, validate=True)
    except Exception:
        nonce_bytes = nonce.encode("utf-8")
    digest = hmac.new(claim_bytes, nonce_bytes, hashlib.sha256).digest()
    return base64.b64encode(digest).decode("ascii")


def verify_room_claim(expected_claim: str, provided_claim: str) -> bool:
    """Constant-time verification of a room claim."""
    if not expected_claim or not provided_claim:
        return False
    return hmac.compare_digest(expected_claim.encode("ascii"), provided_claim.encode("ascii"))


def make_aad(device_id: str) -> bytes:
    """Build Associated Authenticated Data '<deviceId>:v1'."""
    return f"{device_id}:v{RELAY_PROTOCOL_VERSION}".encode("utf-8")


def seal_envelope(
    plaintext: bytes,
    token: str,
    device_id: str,
    *,
    envelope_id: str | None = None,
    ts: int | None = None,
    nonce: bytes | None = None,
) -> dict[str, Any]:
    """Encrypt plaintext into the 5-field Wake PC E2EE JSON envelope."""
    key = derive_key(token, device_id)
    aad = make_aad(device_id)
    iv = nonce if nonce is not None else os.urandom(AES_GCM_NONCE_BYTES)
    if len(iv) != AES_GCM_NONCE_BYTES:
        raise RelayCryptoError(f"Nonce must be {AES_GCM_NONCE_BYTES} bytes")

    ciphertext_and_tag = AESGCM(key).encrypt(iv, plaintext, aad)
    return {
        "v": RELAY_PROTOCOL_VERSION,
        "id": (envelope_id or str(uuid.uuid4())).lower(),
        "ts": int(ts if ts is not None else time.time()),
        "n": base64.b64encode(iv).decode("ascii"),
        "c": base64.b64encode(ciphertext_and_tag).decode("ascii"),
    }


def open_envelope(envelope: dict[str, Any], token: str, device_id: str) -> bytes:
    """Authenticate and decrypt a 5-field Wake PC E2EE JSON envelope."""
    if not isinstance(envelope, dict):
        raise RelayCryptoError("Envelope must be a JSON object")

    n_b64 = envelope.get("n")
    c_b64 = envelope.get("c")
    if not isinstance(n_b64, str) or not isinstance(c_b64, str):
        raise RelayCryptoError("Envelope missing 'n' or 'c' base64 fields")

    try:
        nonce = base64.b64decode(n_b64, validate=True)
        combined = base64.b64decode(c_b64, validate=True)
    except Exception as exc:
        raise RelayCryptoError("Invalid base64 encoding in envelope") from exc

    if len(nonce) != AES_GCM_NONCE_BYTES:
        raise RelayCryptoError("Invalid AES-GCM nonce length")
    if len(combined) <= AES_GCM_TAG_BYTES:
        raise RelayCryptoError("Ciphertext payload too short (must exceed 16-byte GCM tag)")

    key = derive_key(token, device_id)
    aad = make_aad(device_id)
    try:
        return AESGCM(key).decrypt(nonce, combined, aad)
    except InvalidTag as exc:
        raise RelayCryptoError("AES-GCM authentication failed") from exc


def validate_envelope_structure(envelope: Any) -> tuple[bool, str]:
    """Validate relay envelope shape without decrypting (used by zero-knowledge relay)."""
    if not isinstance(envelope, dict):
        return False, "Envelope must be a JSON object"
    if envelope.get("v") != RELAY_PROTOCOL_VERSION:
        return False, "Unsupported protocol version"
    env_id = envelope.get("id")
    if not isinstance(env_id, str) or not env_id or len(env_id) > 128:
        return False, "Invalid envelope id"
    ts = envelope.get("ts")
    if not isinstance(ts, int) or isinstance(ts, bool):
        return False, "Invalid envelope timestamp"
    n_b64 = envelope.get("n")
    c_b64 = envelope.get("c")
    if not isinstance(n_b64, str) or not isinstance(c_b64, str):
        return False, "Missing nonce or ciphertext"
    try:
        nonce = base64.b64decode(n_b64, validate=True)
        combined = base64.b64decode(c_b64, validate=True)
    except Exception:
        return False, "Invalid base64 in nonce or ciphertext"
    if len(nonce) != AES_GCM_NONCE_BYTES:
        return False, "Invalid nonce length"
    if len(combined) <= AES_GCM_TAG_BYTES:
        return False, "Ciphertext shorter than GCM tag"
    return True, ""


def encode_command_payload(path: str, query: dict[str, str] | None = None) -> bytes:
    """Encode internal command payload JSON; omits 'query' when empty (per spec)."""
    payload: dict[str, Any] = {"path": path}
    if query:
        payload["query"] = {str(k): str(v) for k, v in query.items()}
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def decode_command_payload(plaintext: bytes) -> tuple[str, dict[str, str]]:
    """Decode internal command payload JSON into (path, query_dict)."""
    try:
        obj = json.loads(plaintext.decode("utf-8"))
    except Exception as exc:
        raise RelayCryptoError("Invalid command JSON") from exc
    if not isinstance(obj, dict) or not isinstance(obj.get("path"), str):
        raise RelayCryptoError("Command payload missing 'path'")
    raw_query = obj.get("query") or {}
    if not isinstance(raw_query, dict):
        raise RelayCryptoError("Command 'query' must be an object")
    query = {str(k): str(v) for k, v in raw_query.items()}
    return obj["path"], query


def validate_mac(mac: str) -> bool:
    """Validate colon-separated MAC address (AA:BB:CC:DD:EE:FF)."""
    return bool(MAC_REGEX.match(mac.strip()))


def normalize_mac(mac: str) -> str:
    """Normalize valid MAC address to uppercase colon-separated form."""
    cleaned = mac.strip().replace("-", ":").upper()
    if not validate_mac(cleaned):
        raise ValueError(f"Invalid MAC address: {mac}")
    return cleaned


def validate_token(token: str) -> bool:
    """Validate agent Bearer token format ^[A-Za-z0-9_-]{8,64}$."""
    return bool(TOKEN_REGEX.match(token))


def mask_url_token(url: str) -> str:
    """Mask token query parameter before logging URLs."""
    return TOKEN_URL_MASK_REGEX.sub("token=***", url)


def build_wol_magic_packet(mac: str) -> bytes:
    """Build standard 102-byte Wake-on-LAN Magic Packet (6x 0xFF + 16x MAC)."""
    normalized = normalize_mac(mac)
    mac_bytes = bytes.fromhex(normalized.replace(":", ""))
    return b"\xff" * 6 + mac_bytes * 16


def send_wol_packets(
    mac: str,
    broadcast: str = "255.255.255.255",
    port: int = 9,
    repeat: int = 3,
) -> int:
    """Send Wake-on-LAN Magic Packet via UDP SO_BROADCAST (3x by default)."""
    if not (1 <= port <= 65535):
        raise ValueError(f"Invalid WoL port: {port}")
    packet = build_wol_magic_packet(mac)
    sent = 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for _ in range(repeat):
            sock.sendto(packet, (broadcast, port))
            sent += 1
    return sent
