"""Static integrity, localization parity, crypto-spec parity, and zero-ads/zero-paywall checks for app/ios."""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

IOS_ROOT = Path(__file__).resolve().parents[1] / "ios"

EXPECTED_THEMES = {
    "aura", "aurora", "black", "dark", "diamond", "fire", "forest",
    "galaxy", "golden", "grape", "miami", "mint", "neon", "ocean",
    "peachy", "rainbow", "sakura", "sapphire", "sunset", "tropical", "whiskey",
}

FORBIDDEN_MONETIZATION_TOKENS = [
    "import StoreKit",
    "SubscriptionManager",
    "PaywallView",
    "wakepc://paywall",
    "com.wakepc.premium",
    "GoogleMobileAds",
    "GADBannerView",
]


def _parse_strings_file(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r'^\s*"([^"]+)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;', re.MULTILINE)
    return {m.group(1): m.group(2) for m in pattern.finditer(text)}


def test_plists_and_entitlements_are_valid_xml() -> None:
    files = list(IOS_ROOT.rglob("*.plist")) + list(IOS_ROOT.rglob("*.entitlements"))
    assert len(files) == 4
    parsed_map: dict[str, dict] = {}
    for path in files:
        with path.open("rb") as fp:
            parsed = plistlib.load(fp)
        assert isinstance(parsed, dict), f"{path} did not decode to dict"
        parsed_map[path.relative_to(IOS_ROOT).as_posix()] = parsed

    app_info = parsed_map["WakePC/Resources/Info.plist"]
    assert "WakePCAppGroupID" in app_info
    assert "_wakepc._tcp" in app_info.get("NSBonjourServices", [])
    assert app_info.get("CFBundleURLTypes")

    ext_info = parsed_map["WakePCWidgetExtension/Resources/Info.plist"]
    assert "WakePCAppGroupID" in ext_info
    assert ext_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension"

    for ent_path in ("WakePC/Resources/WakePC.entitlements", "WakePCWidgetExtension/Resources/WakePCWidgetExtension.entitlements"):
        ent = parsed_map[ent_path]
        assert ent.get("com.apple.security.application-groups"), f"Missing App Group in {ent_path}"
        assert ent.get("keychain-access-groups"), f"Missing Keychain group in {ent_path}"


def test_zero_paywall_storekit_or_ads() -> None:
    swift_files = list(IOS_ROOT.rglob("*.swift"))
    assert len(swift_files) >= 20
    for path in swift_files:
        text = path.read_text(encoding="utf-8")
        for forbidden in FORBIDDEN_MONETIZATION_TOKENS:
            assert forbidden not in text, f"Forbidden token {forbidden!r} found in {path}"


def test_localization_parity_and_complete_coverage() -> None:
    en_map = _parse_strings_file(IOS_ROOT / "WakePC/Resources/en.lproj/Localizable.strings")
    ru_map = _parse_strings_file(IOS_ROOT / "WakePC/Resources/ru.lproj/Localizable.strings")

    assert en_map, "en Localizable.strings is empty"
    assert set(en_map.keys()) == set(ru_map.keys()), (
        f"EN/RU key mismatch: en_only={set(en_map) - set(ru_map)}, ru_only={set(ru_map) - set(en_map)}"
    )

    en_info = _parse_strings_file(IOS_ROOT / "WakePC/Resources/en.lproj/InfoPlist.strings")
    ru_info = _parse_strings_file(IOS_ROOT / "WakePC/Resources/ru.lproj/InfoPlist.strings")
    assert set(en_info.keys()) == set(ru_info.keys())

    # Every L10n.tr("key") call across all Swift files must exist in Localizable.strings
    tr_regex = re.compile(r'L10n\.tr\(\s*"([^"]+)"')
    referenced_keys: set[str] = set()
    for path in IOS_ROOT.rglob("*.swift"):
        referenced_keys.update(tr_regex.findall(path.read_text(encoding="utf-8")))

    missing_en = referenced_keys - set(en_map.keys())
    missing_ru = referenced_keys - set(ru_map.keys())
    assert not missing_en, f"Missing EN localization keys: {sorted(missing_en)}"
    assert not missing_ru, f"Missing RU localization keys: {sorted(missing_ru)}"


def test_all_21_themes_present_and_free() -> None:
    theme_src = (IOS_ROOT / "Shared/AppTheme.swift").read_text(encoding="utf-8")
    ids = set(re.findall(r'id:\s*"([a-z]+)"', theme_src))
    assert EXPECTED_THEMES.issubset(ids), f"Missing themes: {EXPECTED_THEMES - ids}"
    assert len(ids) == 21


def test_swift_and_python_e2ee_constants_match() -> None:
    swift_crypto = (IOS_ROOT / "Shared/RelayCrypto.swift").read_text(encoding="utf-8")
    assert '"wakepc-relay-v1"' in swift_crypto
    assert '"room-claim"' in swift_crypto
    assert "outputByteCount: 32" in swift_crypto
    assert "gcmTagLength = 16" in swift_crypto
    assert r'"\(deviceId):v\(protocolVersion)"' in swift_crypto


def _strip_swift_comments_and_strings(src: str) -> str:
    """Single-pass Swift scanner stripping comments & string literals while preserving code delimiters."""
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            depth = 1
            i += 2
            while i < n and depth > 0:
                if src[i : i + 2] == "/*":
                    depth += 1
                    i += 2
                elif src[i : i + 2] == "*/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
        elif ch == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    if i + 1 < n and src[i + 1] == "(":
                        # Scan balanced interpolation expression inside string
                        i += 2
                        interp_depth = 1
                        while i < n and interp_depth > 0:
                            if src[i] == "(":
                                interp_depth += 1
                            elif src[i] == ")":
                                interp_depth -= 1
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
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def test_swift_files_have_balanced_delimiters() -> None:
    for path in IOS_ROOT.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        cleaned = _strip_swift_comments_and_strings(text)
        stack: list[str] = []
        pairs = {")": "(", "]": "[", "}": "{"}
        for ch in cleaned:
            if ch in "([{":
                stack.append(ch)
            elif ch in ")]}":
                assert stack and stack[-1] == pairs[ch], f"Unbalanced {ch} in {path}"
                stack.pop()
        assert not stack, f"Unclosed delimiters {stack} in {path}"
