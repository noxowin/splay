# splay

[![Windows build](https://github.com/noxowin/splay/actions/workflows/windows.yml/badge.svg)](https://github.com/noxowin/splay/actions/workflows/windows.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

Syncplay-compatible rooms, synchronized playback, chat and shared playlists inside your existing mpv. No separate Syncplay client required.

**English** · [简体中文](README.zh-CN.md)

**[Download v0.2.0 for Windows x64](https://github.com/noxowin/splay/releases/download/v0.2.0/splay-windows-x64-v0.2.0.zip)** · [Release](https://github.com/noxowin/splay/releases/tag/v0.2.0) · [Install & use](docs/install.md) · [Changelog](CHANGELOG.md) · [Report an issue](https://github.com/noxowin/splay/issues)

splay is an independent project, not an official mpv or Syncplay distribution. It synchronizes playback; everyone supplies their own media.

## Features

- Sync play, pause and seek with Syncplay servers and official clients; view members, readiness and controlled-room permissions.
- Smooth catch-up: when 1.5 to 4 s ahead of the room, play at 0.95x until level instead of jumping back.
- Five-second all-ready countdown and server latency display/sharing, enabled by default after you connect.
- Quick chat with Enter; transparent, full-window message history with Shift+h, continuous chat input and colored nicknames.
- Switch between room chat and scrolling chat; remember the selected mode. Optional smoother scrolling is off by default.
- Compare exact reported durations and adjust a local time offset, including an editable suggestion from another member's duration.
- Share playlists, match local files and explicitly confirm network addresses; local following starts off.
- Named connection profiles, password entry in the mpv input box (visible while typed), Windows-encrypted password memory and bounded reconnect attempts.
- Interface in Simplified Chinese or English, following the Windows display language or chosen in Settings.
- Independent mpv interface with optional uosc integration. Each player starts with splay disabled and connects only when requested.

## Quick start

1. Download the ZIP above and check its SHA256 against the release checksum. Close mpv.
2. Copy all four files into the `scripts` folder of mpv's **active configuration directory**. Replace all four when upgrading:

   ```text
   scripts/splay.lua
   scripts/splay_core.dll
   scripts/splay_overlay.lua
   scripts/splay_playlist.lua
   ```

3. Open your video normally. Press **Shift+s** or click the Sync icon, enable splay, enter a room and connect. Initial server: `syncplay.pl:8999`; nickname: `splayuser`; no default room.
4. Press **Enter** to type/send a quick message, **Esc** to cancel, or **Shift+h** for message history and continuous chat. Open **Settings** for chat mode and room behavior.

Portable mpv commonly uses `portable_config` next to `mpv.exe`; other installations commonly use `%APPDATA%\mpv`. Keep your existing player configuration. GitHub's Source code archives do not include the compiled DLL.

By default, joining a room requests a room-wide pause, and a member leaving the same room also requests a pause, subject to controlled-room permissions. Both options can be disabled in Settings and are remembered. Joining keeps the current media and playback arguments. Playlist following is off by default; sharing or opening unfamiliar network addresses requires explicit confirmation.

## Compatibility and development

Requires Windows x64 mpv with C-plugin and Lua `mp.input` support; uosc is optional. Exact tested versions, validation results and remaining limits are recorded in [v0.2.0 validation](docs/validation-v0.2.0.md). Support for every mpv build, player distribution or browser authentication flow is not implied.

See [Contributing](CONTRIBUTING.md), [Architecture](docs/architecture.md) and [Upstream compatibility](docs/upstream-compatibility.md). Original code is [GPL-3.0-only](LICENSE); third-party files retain their licenses in [Third-party notices](THIRD_PARTY_NOTICES.md). Report security issues as described in [SECURITY.md](SECURITY.md).
