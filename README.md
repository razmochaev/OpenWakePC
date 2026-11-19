<div align="center">

# OpenWakePC

**Free, open-source Wake-on-LAN & encrypted remote PC control ecosystem for iOS, macOS, Windows, and Linux**

[![Latest Release](https://img.shields.io/github/v/release/razmochaev/OpenWakePC?style=flat-square&color=22c55e)](https://github.com/razmochaev/OpenWakePC/releases/latest)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2016.6%2B%20%7C%20macOS%2014%2B%20%7C%20Windows%2010%2F11%20%7C%20Linux-0ea5e9?style=flat-square)](#download)
[![License: MIT](https://img.shields.io/badge/License-MIT-a855f7?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/badge/Author-razmochaev.com-f59e0b?style=flat-square)](https://razmochaev.com)

*Zero ads • Zero subscriptions • Zero third-party SDKs • End-to-End Encrypted Relay (AES-256-GCM)*

</div>

---

## Download

Prebuilt binaries for iPhone, macOS, and Windows are published on the [**GitHub Releases**](https://github.com/razmochaev/OpenWakePC/releases/latest) page:

| Platform | Download | How to install / run |
| --- | --- | --- |
| **iPhone / iPad** (`iOS 16.6+`, `arm64`) | [`OpenWakePC-iOS.ipa`](https://github.com/razmochaev/OpenWakePC/releases/latest/download/OpenWakePC-iOS.ipa) | Unsigned release `.ipa` — sideload via AltStore, SideStore, Sideloadly, TrollStore, or sign & install from Xcode |
| **macOS** (`Apple Silicon arm64`, `macOS 14+`) | [`OpenWakePC-Agent-macOS-arm64.dmg`](https://github.com/razmochaev/OpenWakePC/releases/latest/download/OpenWakePC-Agent-macOS-arm64.dmg) | Open DMG, drag **OpenWakePC Agent.app** to Applications, run from Menu Bar |
| **Windows** (`x64`, `Windows 10/11`) | [`OpenWakePC-Agent-Windows-x64.zip`](https://github.com/razmochaev/OpenWakePC/releases/latest/download/OpenWakePC-Agent-Windows-x64.zip) | Extract and run `OpenWakePCAgent.exe` (self-contained single executable, no runtime install required) |
| **Linux / Python CLI** | Source (`pip install -e ".[agent]"`) | Run `wakepc-agent` (supports headless Linux, Windows, and macOS) |

> **macOS first launch note:** `OpenWakePC Agent.app` is distributed ad-hoc signed without an Apple Developer notarization ticket. If macOS Gatekeeper blocks opening it, run:
> ```bash
> xattr -cr "/Applications/OpenWakePC Agent.app"
> ```
> Then grant **Screen Recording** (for PC Screen streaming) and **Accessibility** (for keyboard/mouse control) when prompted in *System Settings → Privacy & Security*.

---

## Features

- **Wake-on-LAN & Smart Power:** Instant WoL Magic Packets over Wi-Fi, **Buddy Wake** (wake one computer through another online agent when away from home), Shutdown, Restart, Sleep, Lock, Display Off, countdown timers, idle automation, and **Arrive-Home Geofencing (~150 m)**.
- **Zero-Config Discovery & DHCP Auto-Heal:** One-tap LAN discovery via Bonjour (`_wakepc._tcp`) and subnet scan, or QR pairing (`wakepc://config?...`). Automatically detects DHCP IP renewals on macOS and heals stale IPs on iPhone in ~1–2s via Bonjour/LAN.
- **Live PC Screen + System Audio:** Smooth on-demand `ScreenCaptureKit` screen streaming up to **20 FPS** with synchronized `24 kHz` system audio over local Wi-Fi (plus adaptive fallback over E2EE Relay), pinch-to-zoom (1x–5x), landscape fullscreen, and Save to Photos.
- **Media, Volume, Mic & Hardware Brightness:** System volume & microphone sliders + one-tap audio output/input switcher; native display brightness control combining macOS `DisplayServices` and **hardware DDC/CI (`IOAVService` I2C VCP `0x10`)** for external monitors.
- **Touchpad, Keyboard & Files:** Smooth 1-finger/2-finger trackpad gestures, text input, hotkeys, bidirectional clipboard sync, browser URL opener, custom 1-tap launch buttons, running app manager, and LAN file upload (up to 500 MB).
- **Deep iOS Integration:** Home Screen & Lock Screen interactive widgets, 4 Control Center controls (iOS 18+), 2 Live Activities, 10 Siri / Apple Shortcuts App Intents, Face ID confirmation for power actions, and 21 built-in themes (EN / RU).
- **Zero-Knowledge E2EE Relay:** End-to-end **AES-256-GCM** encryption (`HKDF-SHA256` with `wakepc-relay-v1` + `HMAC-SHA256` room claims). Works out of the box or with your own Docker-hosted [`relay/`](relay/).

---

## Architecture (`OpenWakePC`)

| Component | Path | Stack | Purpose |
| --- | --- | --- | --- |
| **iOS App & Widgets** | [`ios/`](ios/) | Swift 5 + SwiftUI + WidgetKit + ActivityKit + AppIntents | Native iPhone/iPad/Mac Catalyst control app (**0 third-party SDKs**) |
| **macOS Menu Bar Agent** | [`macos/WakePCAgent/`](macos/WakePCAgent/) | Swift 5 + SwiftUI + ScreenCaptureKit + IOKit + CoreAudio | Native macOS Menu Bar server (`:8765`), DDC/CI, audio, input & live Bonjour |
| **Windows Tray Agent** | [`windows/WakePCAgent/`](windows/WakePCAgent/) | C# / .NET 8.0 WPF + NAudio + WMI + QRCoder | Native Windows system-tray agent, firewall/autostart setup & QR |
| **CLI Agent (Linux/Win/Mac)** | [`agent/`](agent/) | Python (`aiohttp`, `cryptography`, `zeroconf`) | Lightweight cross-platform headless or desktop agent |
| **Self-Hosted E2EE Relay** | [`relay/`](relay/) | Python (`aiohttp`) + Docker | Zero-knowledge WebSocket relay server (`/agent/{id}`, `/send/{id}`) |
| **Shared Crypto & WoL** | [`common/`](common/) | Python (`cryptography`) | Reference `wakepc-relay-v1` E2EE implementation matching Swift/C# |

---

## Quick Start (Self-Hosted Relay & CLI Agent)

### Run your own E2EE Relay (Docker)

```bash
docker build -f relay/Dockerfile -t openwakepc-relay .
docker run -d -p 8787:8787 \
  -e WAKEPC_RELAY_PUBLIC_URL=https://relay.example.com \
  openwakepc-relay
```

### Run CLI Agent (Linux / macOS / Windows)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[agent,dev]"
wakepc-agent --relay-url https://relay.example.com
```

---

## Build From Source

- **CI Pipeline:** Automatic builds and tests for Linux, Windows, macOS, and iOS live in [`.github/workflows/build.yml`](.github/workflows/build.yml).
- **iOS (macOS + Xcode 16+):**
  ```bash
  brew install xcodegen
  cd ios && xcodegen generate && open WakePC.xcodeproj
  ```
- **macOS Agent (macOS + Xcode 16+):**
  ```bash
  cd macos/WakePCAgent && xcodegen generate
  xcodebuild -project WakePCAgent.xcodeproj -scheme WakePCAgent -configuration Release CODE_SIGNING_ALLOWED=NO build
  ```
- **Windows Agent (.NET 8 SDK):**
  ```powershell
  dotnet publish windows/WakePCAgent/WakePCAgent.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o dist/win-x64
  ```
- **Run Automated Tests:**
  ```bash
  pip install -e ".[dev]"
  pytest -v
  ```

---

## Author & Links

Created and maintained by **razmochaev**.

- Website: [razmochaev.com](https://razmochaev.com)
- GitHub Repository: [github.com/razmochaev/OpenWakePC](https://github.com/razmochaev/OpenWakePC)
- Downloads: [Latest Releases](https://github.com/razmochaev/OpenWakePC/releases/latest)
- License: [MIT](LICENSE)
