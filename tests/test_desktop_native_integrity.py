"""Static integrity, localization parity, crypto parity, and route coverage checks for native macOS & Windows agents."""

from __future__ import annotations

import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[1]
MAC_ROOT = APP_ROOT / "macos/WakePCAgent"
WIN_ROOT = APP_ROOT / "windows/WakePCAgent"

REQUIRED_ROUTES = [
    "/status", "/telemetry", "/shutdown", "/restart", "/sleep", "/hibernate", "/lock",
    "/display-off", "/display-on", "/wake-other", "/shutdown-in", "/restart-in", "/sleep-in",
    "/scheduled-status", "/cancel-scheduled", "/idle-action", "/idle-notify",
    "/volume-set/", "/volume-up", "/volume-down", "/volume-mute",
    "/audio-outputs", "/audio-output/set",
    "/brightness-set/", "/brightness-up", "/brightness-down",
    "/media-play-pause", "/media-next", "/media-prev", "/media-fullscreen",
    "/screenshot", "/apps", "/apps/close", "/commands", "/command/run", "/command/close",
    "/open-url", "/clipboard", "/clipboard/get", "/upload",
    "/mouse/move", "/mouse/scroll", "/mouse/click", "/mouse/drag", "/key/text", "/key/press",
]

FORBIDDEN_TOKENS = [
    "StoreKit", "PaywallView", "SubscriptionManager", "wakepc://paywall",
    "GoogleMobileAds", "GADBannerView", "Sparkle",
]


def _parse_strings(path: Path) -> dict[str, str]:
    pattern = re.compile(r'^\s*"([^"]+)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', re.MULTILINE)
    return {m.group(1): m.group(2) for m in pattern.finditer(path.read_text(encoding="utf-8"))}


def _check_balanced_c_like(path: Path) -> None:
    src = path.read_text(encoding="utf-8")
    out: list[str] = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and src[i : i + 2] != "*/":
                i += 1
            i += 2
        elif ch == '"':
            # Handle C# verbatim/raw strings or standard strings
            if src[i : i + 3] == '"""':
                end = src.find('"""', i + 3)
                i = (end + 3) if end >= 0 else n
            else:
                i += 1
                while i < n:
                    if src[i] == "\\":
                        if i + 1 < n and src[i + 1] == "(":
                            i += 2
                            depth = 1
                            while i < n and depth > 0:
                                if src[i] == "(":
                                    depth += 1
                                elif src[i] == ")":
                                    depth -= 1
                                elif src[i] == '"':
                                    i += 1
                                    while i < n and src[i] != '"':
                                        if src[i] == "\\":
                                            i += 1
                                        i += 1
                                i += 1
                        else:
                            i += 2
                    elif src[i] == '"':
                        i += 1
                        break
                    else:
                        i += 1
        elif ch == "'" and path.suffix == ".cs":
            i += 1
            while i < n and src[i] != "'":
                if src[i] == "\\":
                    i += 1
                i += 1
            i += 1
        else:
            out.append(ch)
            i += 1

    stack: list[str] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for ch in "".join(out):
        if ch in "([{":
            stack.append(ch)
        elif ch in ")]}":
            assert stack and stack[-1] == pairs[ch], f"Unbalanced {ch} in {path}"
            stack.pop()
    assert not stack, f"Unclosed {stack} in {path}"


def test_macos_agent_integrity_and_localizations() -> None:
    with (MAC_ROOT / "Resources/Info.plist").open("rb") as fp:
        plist = plistlib.load(fp)
    assert plist["LSUIElement"] is True
    assert "_wakepc._tcp" in plist["NSBonjourServices"]

    en = _parse_strings(MAC_ROOT / "Resources/en.lproj/Localizable.strings")
    ru = _parse_strings(MAC_ROOT / "Resources/ru.lproj/Localizable.strings")
    assert set(en.keys()) == set(ru.keys())

    tr_regex = re.compile(r'L10nMac\.tr\(\s*"([^"]+)"')
    refs: set[str] = set()
    for p in MAC_ROOT.rglob("*.swift"):
        txt = p.read_text(encoding="utf-8")
        refs.update(tr_regex.findall(txt))
        for bad in FORBIDDEN_TOKENS:
            assert bad not in txt, f"Forbidden {bad} in {p}"
        _check_balanced_c_like(p)
    assert not (refs - set(en.keys())), f"Missing Mac l10n keys: {refs - set(en.keys())}"

    crypto = (MAC_ROOT / "Core/RelayCrypto.swift").read_text(encoding="utf-8")
    assert '"wakepc-relay-v1"' in crypto and '"room-claim"' in crypto and "outputByteCount: 32" in crypto

    http_src = (MAC_ROOT / "Core/HTTPServer.swift").read_text(encoding="utf-8")
    for route in REQUIRED_ROUTES:
        assert route in http_src, f"Missing route {route} in macOS HTTPServer.swift"


def test_windows_agent_integrity_and_routes() -> None:
    # Validate XML of .csproj and .xaml files
    for xml_file in list(WIN_ROOT.rglob("*.csproj")) + list(WIN_ROOT.rglob("*.xaml")):
        ET.parse(xml_file)

    cs_files = list(WIN_ROOT.rglob("*.cs"))
    assert len(cs_files) >= 6
    for p in cs_files:
        txt = p.read_text(encoding="utf-8")
        for bad in FORBIDDEN_TOKENS:
            assert bad not in txt, f"Forbidden {bad} in {p}"
        _check_balanced_c_like(p)

    crypto = (WIN_ROOT / "Core/RelayCrypto.cs").read_text(encoding="utf-8")
    assert '"wakepc-relay-v1"' in crypto and '"room-claim"' in crypto and "outputLength: 32" in crypto

    http_src = (WIN_ROOT / "Core/HttpAgentServer.cs").read_text(encoding="utf-8")
    for route in REQUIRED_ROUTES:
        assert route in http_src, f"Missing route {route} in Windows HttpAgentServer.cs"

    # Regression guards against SDK/platform compilation traps
    assert "PerformanceCounter" not in (WIN_ROOT / "Core/WindowsSystem.cs").read_text(encoding="utf-8")
    assert "CGDisplayCreateImage" not in (MAC_ROOT / "Core/MacSystemController.swift").read_text(encoding="utf-8")
    for ios_file in ("ios/Shared/ActivityAttributes.swift", "ios/WakePC/Services/DeviceServices.swift", "ios/WakePC/Services/WatchSyncService.swift"):
        assert "macCatalyst" in (APP_ROOT / ios_file).read_text(encoding="utf-8"), f"Missing Mac Catalyst guard in {ios_file}"
