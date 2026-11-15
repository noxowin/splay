# v0.1.1 validation

Recorded on 2026-11-14 for the v0.1.1 pre-release. Everything below was run on one maintainer machine with isolated player configurations, synthetic media, temporary local rooms and generated test passwords. No personal player configuration, saved credentials or private media is included in the repository or download. Changes since v0.1.0 are listed in the [changelog](https://github.com/noxowin/splay/blob/v0.1.1/CHANGELOG.md).

## Environment

- Windows 11 x64, version 10.0.26200.9168. Python 3.12.4. MinGW-Builds GCC 14.2.0 (`x86_64-w64-mingw32`, win32 threads, SEH, UCRT).
- mpv `v0.41.0-dev-g41f6a6450`, built 2025-12-21 with FFmpeg `git-2025-12-21-1fcb201` and libplacebo v7.358.0. uosc 5.13.0.
- Unmodified Syncplay 1.7.6 client and server, commit `993232ab095bb810593459bc705b3e6fc64ad161`. All 171 files of the local archive were compared byte for byte with the extracted tree; none is missing or changed, and the archive's own comment names that commit. The local archive's SHA256 is `90481460a71580237f1ce78b69061f63556e53d13815d75e21aa0553cef8bc9e`, which is not the value written in the v0.1.0 record; the reason was not investigated.
- Official test dependencies: Twisted 26.4.0, pyOpenSSL 26.4.0, cryptography 50.0.2, service-identity 26.1.0, pywin32 312.
- Reference media: 180 seconds, 320×180, 10 fps.

All results below were obtained with one DLL, SHA256 `7ad64f406414d987b90bbfcf6f86cb229ecd342b425eb9b30beaae9648600613`. Builds are not byte-reproducible; a rebuild of the same source has a different hash.

## Player launch arguments

| Harness | mpv arguments |
| --- | --- |
| Official interoperability | `--no-config --vo=null --ao=null --pause=yes --idle=yes --script=build/splay_core.dll --script=<observer>` with the test media. The official client starts its own mpv through `syncplayClient.py --no-gui --no-store --player-path <mpv> … -- --vo=null --ao=null --pause=yes --no-config` |
| UI smoke, native | `--no-config --load-scripts=no --config-dir=<isolated> --idle=yes --force-window=yes --geometry=1100x800 --ao=null --pause=yes --osd-fonts-dir=<uosc fonts> --script=scripts/splay.lua --script=tests/ui/driver.lua` |
| UI smoke, uosc | The native arguments plus `--script=<uosc 5.13.0>` |
| Forms and playlist forms | `--no-config --load-scripts=no --config-dir=<isolated> --idle=yes --vo=null --ao=null --script=<fixture>` |
| Latency overlay | `--no-config --load-scripts=no --force-window=yes --window-minimized=yes --geometry=1100x800 --ao=null --pause=yes --input-ipc-server=<pipe> --script=scripts/splay_overlay.lua` |
| Offline offset and password box | `--load-scripts=no --config-dir=<isolated> --force-window=yes --geometry=960x540 --ao=null --pause=yes --idle=yes --input-ipc-server=<pipe>` and `--script=` for each of the four runtime files |

The history-restart and overlay-review fixtures set their own arguments; see the scripts under `tests/ui/`.

## Native checks

All eight suites passed: `core`, `reconnect`, `latency`, `autostart`, `room-policy`, `history`, `credentials` and `net`, and so did `tls-rejection`, which serves a self-signed certificate and expects no connection and no plaintext fallback. The credentials suite ran under the normal Windows user account because DPAPI is account-bound; no cross-account test is claimed.

The `net` suite failed once during this work. The cause was in its driver, not in the transport: the transport queues an event and calls the owner back right after, and the driver could poll the event before the callback had been counted. That happened in 6 of 1500 short connections, with the v0.1.0-based build as well. The driver now waits briefly for the callback; 3000 connections then passed.

## TLS

With `SCH_USE_STRONG_CRYPTO` added to the Schannel credentials, a `require`-mode STARTTLS handshake against the public server `syncplay.pl` completed on ports 8997, 8998 and 8999. The test disconnects as soon as the handshake finishes; it does not log in or join a room. Before the change the same handshake had succeeded on ports 8998 and 8999. No server offering only weak algorithms was available, so their rejection is not tested.

## Official-client interoperability

Six suites passed against the unmodified official client and server with real mpv processes, not protocol doubles.

| Suite | Checks passed | Coverage |
| --- | --- | --- |
| Local file | 77 | Late join, room-wide join and leave pause, empty-room position, bidirectional play, pause, seek and chat, rapid pause changes, positive and negative offsets, boundary hold and recovery, controlled-room creation, authentication and permissions, manual reconnect, 30-second paused heartbeat, media stop and reload, playback after server loss |
| HTTP | 80 | The same over two distinct authenticated loopback URLs, with safe late titles and hidden URL fallbacks |
| Latency | 24 | Off by default, heartbeat measurement, sharing between two plugin players, the official client unaffected, withdrawal, room change. Latency is read from the separate `splay-latency` message, and the state is checked to carry none |
| All-ready autostart | 148 | Countdown start, cancellation, readiness changes, members leaving, permissions, reconnect |
| Shared playlist | 46 | Bidirectional edits with the official client, permissions, wire limits, explicit following |
| Official-server reconnect | 11 | Server restart, room, permissions and media preserved |

## Interface tests

These use real mpv with a mocked core or mocked protocol state. They do not substitute for the official-client tests.

- `tests/ui/smoke.py`: the native path and the uosc path, each loading the production main script in a real window, plus the forms and playlist-forms fixtures. The forms fixture covers the new latency message: it is passed to the overlay unchanged, does not resend the state, does not reach the playlist script, malformed messages are dropped, and an overlay that starts late receives the current values.
- `tests/ui/latency_overlay.py`: the production overlay in a real window. A latency message alone updates the member rows; a state without latency fields keeps them; unreported, stale, out-of-range and withdrawn values are hidden.
- `tests/ui/history_restart.py`: three real DLL and Lua player processes restoring connection drafts and preferences.
- `tests/ui/overlay_review.py --mode all`: the overlay in native and uosc windows.

## Offline time offset and password box

The v0.1.0-to-v0.1.1 change that lets the core rest while disconnected left these two paths unconfirmed. They were exercised in one session on a real, visible mpv window running the DLL and the three scripts from this tree, against an unmodified official server protected by a generated password, with a second plugin player in the room as the reference for room time.

Nobody watched the screen. The session was driven from outside the player: splay menu actions and player commands over mpv's IPC, real console key presses for the offset prompt, and window messages to the password box. What was read back is the player's own properties, the state the overlay receives, and the window's class, style and lifetime. To read them, a short shim was prepended to the copies of the main and overlay scripts; it mirrors the state, notices and the arrival of a password-box result into player properties, and the production code still handles every message. It was a one-off script, not a suite in this repository, and it is not rerun by CI.

Offline time offset, each step observed:

- Disconnected and paused at 50, three "+1" menu steps give offset +3 and move the player to 53. Typing 20 into the prompt moves it to 70. The player stays paused and disconnected.
- With the offset set, offline play, pause and seek behave normally; a seek to 60 stays at 60.
- Reset moves the player from 60 to 40: the offset is taken off the current position.
- Loading different media clears the offset.
- Joining a room paused at 40 with offset 20 set beforehand puts the player at 60 and leaves the room at 40. In the room, a local seek to 100 moves the room to 80 and a room seek to 30 moves the player to 50.
- Disconnecting keeps the offset, and an offline seek no longer reaches the room. Reconnecting applies it again: 50 for a room at 30.

A defect was found here and fixed before these results were recorded. With no offset and no connection the core does not watch the player, yet it kept the position reference from the previous offset or from the last connection. After an offline seek to 100, setting −1 put the player at 39. v0.1.0 does not have this problem. Setting an offset in that resting state now starts from the player's current position: the same steps give 99, and after leaving a room with no offset, a seek to 120 followed by +1 gives 121. Two cases in the `core` suite cover it.

Password box, each step observed while disconnected:

- The box is a separate visible window whose edit control has the password style; the mpv console stays closed.
- Behind the open box the player still plays, pauses and seeks, and the offset is unchanged.
- Esc and the window's close button both cancel. Each result reached the interface within the 0.1-second resolution of the check.
- Asking twice leaves a single box. Disabling splay closes it.
- A wrong password is accepted by the box and refused by the official server. Automatic reconnect was switched off for this session, so nothing is claimed here about retries.
- The right password connects. With `remember_password=no` no credential file is written.
- Quitting mpv with the box open closes it and exits with code 0 in about 0.2 seconds.

## Archive and source checks

The plugin-only archive passed the independent allowlist and byte-for-byte input check, x64 DLL inspection, vendored-file SHA256 checks, license and notices inclusion, and ZIP checksum verification. Extracting it into an isolated configuration loaded all four runtime files, received native status, opened the panel and exited cleanly. That package smoke test first failed about every other run, and did the same with the published v0.1.0 archive: its driver checked for the panel at a fixed 1.5 seconds, and player startup on this machine sometimes takes longer. The driver now waits for the panel for up to 8 seconds; 16 consecutive runs then passed. Local Markdown links were checked.

No tag, release or download existed when this was written. The archive checked here was built locally; a published archive has its own checksum.

## Reproduce

See [Contributing](https://github.com/noxowin/splay/blob/v0.1.1/CONTRIBUTING.md) for dependencies. Outputs go into ignored `.local` directories. Run `tls-rejection` with the Python that has `cryptography` installed.

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py reconnect
python tools/check.py latency
python tools/check.py autostart
python tools/check.py room-policy
python tools/check.py history
python tools/check.py credentials
python tools/check.py net
.venv\Scripts\python.exe tools/check.py tls-rejection
python tests/ui/smoke.py
python tests/ui/history_restart.py
python tests/ui/latency_overlay.py
python tests/ui/overlay_review.py --mode all
python tests/integration/interop.py
python tests/integration/interop.py --http
python tests/integration/latency_interop.py
python tests/integration/autostart_interop.py
python tests/integration/playlist_interop.py
python tests/integration/reconnect_official.py
python tools/package.py
python tools/verify_release.py --archive dist/splay-windows-x64-v0.1.1.zip --require-license
python tests/ui/package_smoke.py --archive dist/splay-windows-x64-v0.1.1.zip
```

## Not covered

- Only the listed Windows, mpv and uosc versions. Other distributions, mpv.net, the minimum supported mpv, live streams and ad timelines are unverified. Browser launch and authentication chains remain excluded.
- The offline-offset and password-box session was scripted, as described above. How the box and the menus look to a person, and keyboard focus, were not judged by eye. The operator-password and create-room uses of the box were not part of that session.
- Rejection of a server that offers only weak cipher algorithms.
- Fallback when the first resolved address does not answer. There is no reproducible environment for it; only the refused-address fallback is tested.
- Actual CPU use while the core rests was not measured.
- Latency display was not compared against a public server; only the TLS handshake used one.
- The concurrent history test passed in the runs made here. That does not prove the occasional failure seen before the file-lock change is gone.
- The five core suites under AddressSanitizer and UndefinedBehaviorSanitizer, the Lua syntax check and the Windows CI build were not run in this round; they run in GitHub Actions on push. The scripts were loaded by real mpv in the interface tests.
- Mixing a v0.1.0 DLL with v0.1.1 scripts, or the reverse, was not tested. By design latency is then not shown.
- The limits recorded for v0.1.0 still apply: duration equality does not establish identical content, the all-ready countdown has no cross-client leader election, peer latency is self-reported, network titles depend on player metadata, DPAPI storage is tied to the current Windows account, and smoother scrolling chat duplicates frames.

中文：本版区分真实官方互通与模拟协议的界面检查；离线时间偏移与密码输入框由脚本驱动真实播放器窗口逐项确认，并非人工目视。上述环境之外不承诺普遍兼容。安装与功能说明见[中文指南](install.zh-CN.md)。
