# v0.2.0 validation

Recorded on 2026-11-17 for the v0.2.0 release. Everything below was run on one maintainer machine with isolated player configurations, synthetic media, temporary local rooms and generated test passwords. No personal player configuration, saved credentials or private media is included in the repository or download. Changes since v0.1.1 are listed in the [changelog](https://github.com/noxowin/splay/blob/v0.2.0/CHANGELOG.md): smooth catch-up, an English interface, and passwords typed into mpv's input box instead of a native dialog.

## Environment

- Windows 11 x64, version 10.0.26200.9168. Python 3.12.4. MinGW-Builds GCC 14.2.0 (`x86_64-w64-mingw32`, win32 threads, SEH, UCRT). The system display language is Simplified Chinese.
- mpv `v0.41.0-dev-g41f6a6450`, built 2025-12-21 with FFmpeg `git-2025-12-21-1fcb201` and libplacebo v7.358.0. uosc 5.13.0.
- Unmodified Syncplay 1.7.6 client and server, commit `993232ab095bb810593459bc705b3e6fc64ad161`, from a local archive with SHA256 `90481460a71580237f1ce78b69061f63556e53d13815d75e21aa0553cef8bc9e` (compared file by file for v0.1.1: 171 files, none missing or changed).
- Official test dependencies: Twisted 26.4.0, pyOpenSSL 26.4.0, cryptography 50.0.2, service-identity 26.1.0, pywin32 312.
- Reference media: 180 seconds, 320×180, 10 fps.

All results below were obtained with one DLL, SHA256 `1b183d6258b39c9ebc5b9645248a133325da692e7f371fc5f14d9fcaf11281a3`, built from the release source. That is the DLL in the download. Builds are not byte-reproducible; a rebuild of the same source has a different hash.

## Player launch arguments

| Harness | mpv arguments |
| --- | --- |
| Official interoperability | `--no-config --vo=null --ao=null --pause=yes --idle=yes --script=build/splay_core.dll --script=<observer>` with the test media; the catch-up suite adds `--save-position-on-quit --watch-later-dir=<isolated>`. The official client starts its own mpv through `syncplayClient.py --no-gui --no-store --player-path <mpv> … -- --vo=null --ao=null --pause=yes --no-config` |
| UI smoke, native | `--no-config --load-scripts=no --config-dir=<isolated> --idle=yes --force-window=yes --geometry=1100x800 --ao=null --pause=yes --osd-fonts-dir=<uosc fonts> --script=scripts/splay.lua --script=tests/ui/driver.lua` |
| UI smoke, uosc | The native arguments plus `--script=<uosc 5.13.0>` |
| Forms and playlist forms | `--no-config --load-scripts=no --config-dir=<isolated> --idle=yes --vo=null --ao=null --script=<fixture>` |
| Offline path and credentials | `--load-scripts=no --config-dir=<isolated> --vo=null --ao=null --pause=yes --idle=yes --input-ipc-server=<pipe>` and `--script=` for each of the four runtime files |

Every test that opens a real window starts mpv with a show-without-activating command (minimized where the test allows it), so test runs do not take the keyboard. A 30 ms foreground-window sampler ran alongside every window-opening test listed below and never saw a test window in the foreground.

## Native checks

All nine suites passed: `core`, `reconnect`, `latency`, `autostart`, `room-policy`, `catchup` (new), `history`, `credentials` and `net`, and so did `tls-rejection` (a self-signed certificate is refused with no plaintext fallback), the interface translation coverage check `i18n`, and the vendored-source check. The credentials suite ran under the normal Windows user account because DPAPI is account-bound.

The `catchup` suite was also run against four deliberately broken copies of the core during development (no check for the room clock being this player's own report, no restore on new media, a user speed not recognised, a rewind at 1.5 s); each failed at the matching assertion.

## TLS

A `require`-mode STARTTLS handshake against the public server `syncplay.pl` completed on ports 8997, 8998 and 8999. The test disconnects as soon as the handshake finishes; it does not log in or join a room.

## Official-client interoperability

Seven suites passed against the unmodified official client and server with real mpv processes, not protocol doubles, each on its first run on the release DLL.

| Suite | Checks passed | Coverage |
| --- | --- | --- |
| Local file | 76 | Late join, room-wide join and leave pause, empty-room position, bidirectional play, pause, seek and chat, rapid pause changes, positive and negative offsets, boundary hold and recovery, controlled-room creation, authentication and permissions, manual reconnect, 30-second paused heartbeat, media stop and reload, playback after server loss |
| HTTP | 79 | The same over two distinct authenticated loopback URLs, with safe late titles and hidden URL fallbacks; one official-client restart |
| Latency | 24 | Off by default, heartbeat measurement through the separate latency message, sharing between two plugin players, the official client unaffected, withdrawal, room change |
| All-ready autostart | 148 | Countdown start, cancellation, readiness changes, members leaving, permissions, reconnect |
| Shared playlist | 46 | Bidirectional edits with the official client, permissions, wire limits, explicit following |
| Official-server reconnect | 11 | Server restart, room, permissions and media preserved |
| Smooth catch-up (new) | 38 | See the next section; one official-client restart |

The local and HTTP suites count one check fewer than for v0.1.1 because waiting for the official observer is now part of starting the official client.

The official client gives its own mpv 10 s to open its IPC pipe; on this machine a normal start takes 2 to 11 s. When it runs out, the client logs "MPV start timed out" and recovers some 20 s later in a different room state. The suites now stop such a client with its mpv and start it again, up to three times, and report each restart.

## Smooth catch-up

`tests/integration/catchup_interop.py` slows the official client's own mpv so that splay drifts ahead of the room by a controlled amount; the official server's room clock follows its slowest watcher. On the release DLL it checked, in order: at a lead of about 2 s the plugin played at 0.95x with no jump back; with the official player sped up the plugin came level and returned to 1x with a `normal` event; a lead that kept growing past 4 s was rewound and 1x restored; a speed of 1.25x set by the user during a catch-up was left alone, synchronization was suspended and resumed when the user went back to 1x; with catch-up switched off a lead past 1.5 s was sought back and the speed never changed; disconnecting during a catch-up restored 1x and `speed` in `watch-later-options`; quitting during a catch-up with `--save-position-on-quit` saved `start=` and no `speed=` line.

Before that change was made, quitting mpv while it played at 0.95x saved `speed=0.950000` in the watch-later file, with `save-position-on-quit` and with `quit-watch-later`, and restoring the speed in an `on_unload` hook or at shutdown was too late. Taking the exact entry `speed` out of the runtime `watch-later-options` while slowed prevented it in both cases.

## Interface tests

These use real mpv with a mocked core or mocked protocol state. They do not substitute for the official-client tests.

- `tests/ui/smoke.py`: native and uosc entry points in a real window, plus the forms and playlist-forms fixtures. The forms fixture covers the smooth catch-up switch, its `splay.conf` default and automation, and the catch-up notices, alongside the existing language, password-prompt and latency cases.
- `tests/ui/latency_overlay.py` and `tests/ui/history_restart.py` (three real DLL and Lua player processes).
- `tests/ui/overlay_review.py --mode all`: the overlay in native and uosc windows.
- `tests/ui/review.py` and `tests/ui/review.py --language en`: 18 captures each, in Chinese and in English.

## Offline path and password prompt

`tests/integration/offline_path.py` ran with `--language zh-CN`, `--language en` and without the option (`auto`, which resolved to Simplified Chinese on this machine), and `tests/integration/credential_ui_path.py` ran once, all against unmodified official servers protected by generated passwords. They cover what a disconnected player does while the core rests (local time offset set and typed offline, a seek made while resting, joining after offline play), joining, leaving and rejoining with an offset, and the password prompt: opened while disconnected, Esc and closing without a submit, a wrong password refused by the server, the right one connecting, a saved server password reused by a new process without typing it again, port isolation, controlled-room creation and operator authentication, and quitting with the prompt open.

One English run failed during this validation: a key sent to the prompt over mpv's IPC did not arrive, the shortened password was refused, and the test timed out. Three reruns passed. Both tests now read the length of the prompt's line from their probe (never its content) and type the password again if it does not match; with that in place the four runs above passed without needing to retype.

Typed passwords are visible in the player and reach mpv's log: measured on mpv v0.41.0-dev with a synthetic password, any `--log-file` contains it keystroke by keystroke whatever `--msg-level` says, and terminal output shows it at `debug` level. The installation guides, README and SECURITY.md say so.

## Archive and source checks

`python tools/package.py` built `splay-windows-x64-v0.2.0.zip` from the validated DLL and this record. The plugin-only archive passed the independent 19-file allowlist and byte-for-byte input check, x64 DLL inspection, vendored-file SHA256 checks, license and notices inclusion, and ZIP checksum verification. The checksum file now ends in LF, and `sha256sum -c` accepts it. Extracting the archive into an isolated configuration loaded all four runtime files, received native status, opened the panel and exited cleanly. Local Markdown links were checked.

The checksum of the archive checked here is in the release's `.sha256` file; the DLL inside it is the one named under Environment.

## Reproduce

See [Contributing](https://github.com/noxowin/splay/blob/v0.2.0/CONTRIBUTING.md) for dependencies. Outputs go into ignored `.local` directories. Run `tls-rejection` with the Python that has `cryptography` installed.

```powershell
python tools/build.py build
python tools/verify_release.py --sources-only
python tools/check.py i18n
python tools/check.py core
python tools/check.py reconnect
python tools/check.py latency
python tools/check.py autostart
python tools/check.py room-policy
python tools/check.py catchup
python tools/check.py history
python tools/check.py credentials
python tools/check.py net
.venv\Scripts\python.exe tools/check.py tls-rejection
python tests/ui/smoke.py
python tests/ui/history_restart.py
python tests/ui/latency_overlay.py
python tests/ui/overlay_review.py --mode all
python tests/ui/review.py
python tests/ui/review.py --language en
python tests/integration/credential_ui_path.py
python tests/integration/offline_path.py --language zh-CN
python tests/integration/offline_path.py --language en
python tests/integration/offline_path.py
python tests/integration/interop.py
python tests/integration/interop.py --http
python tests/integration/latency_interop.py
python tests/integration/autostart_interop.py
python tests/integration/playlist_interop.py
python tests/integration/reconnect_official.py
python tests/integration/catchup_interop.py
python tools/package.py
python tools/verify_release.py --archive dist/splay-windows-x64-v0.2.0.zip --require-license
python tests/ui/package_smoke.py --archive dist/splay-windows-x64-v0.2.0.zip
```

## Not covered

- Only the listed Windows, mpv and uosc versions. Other distributions, mpv.net, the minimum supported mpv, live streams and ad timelines are unverified. Browser launch and authentication chains remain excluded.
- No person watched or listened during a catch-up; how 0.95x looks and sounds with mpv's default pitch correction is not assessed. Catch-up was tested only against the unmodified 1.7.6 server, whose room clock follows the slowest watcher; another server may behave differently. Controlled rooms take the same code path but have no catch-up case of their own. The watch-later handling was confirmed only on the mpv build above.
- `auto` choosing English was only checked with a mocked state, because this machine's display language is Chinese. The English translation was not reviewed by a native speaker. The longest settings row was checked at 1100 px only.
- Passwords were typed by keys sent over IPC, not by a person; input methods (IME) and opening the prompt by clicking in a real uosc menu were not tried.
- Mixing runtime files from different versions is not supported and was not tested. After a language switch the history file holds a `language` preference that a v0.1.1 DLL refuses, so it cannot read that history.
- Rejection of a server offering only weak cipher algorithms, and fallback when the first resolved address does not answer, have no reproducible test. Actual CPU use while the core rests was not measured.
- `tests/integration/ui_path.py` and `playlist_ui_path.py` already failed on v0.1.1 and were not run.
- The limits recorded for v0.1.0 still apply: duration equality does not establish identical content, the all-ready countdown has no cross-client leader election, peer latency is self-reported, network titles depend on player metadata, DPAPI storage is tied to the current Windows account, and smoother scrolling chat duplicates frames.

中文：本版区分真实官方互通与模拟协议的界面检查；密码输入经 mpv IPC 发送按键，并非人工输入；平滑追赶的观感与听感未经人工评估。上述环境之外不承诺普遍兼容。安装与功能说明见[中文指南](install.zh-CN.md)。
