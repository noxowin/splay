# v0.2.1 validation

Recorded on 2026-11-26 for the v0.2.1 release. Everything below was run on one maintainer machine with isolated player configurations, synthetic media, temporary local rooms and generated test passwords. No personal player configuration, saved credentials or private media is included in the repository or download. Changes since v0.2.0 are listed in the [changelog](https://github.com/noxowin/splay/blob/v0.2.1/CHANGELOG.md): clearly different nickname colours, nicknames coloured in the status lines, and repaired real-player tests. Only the Lua interface scripts changed; the native source (`src/`) is identical to v0.2.0.

## Environment

- Windows 11 x64, version 10.0.26200.9168. Python 3.12.4. MinGW-Builds GCC 14.2.0 (`x86_64-w64-mingw32`, win32 threads, SEH, UCRT). The system display language is Simplified Chinese.
- mpv `v0.41.0-dev-g41f6a6450`, built 2025-12-21 with FFmpeg `git-2025-12-21-1fcb201` and libplacebo v7.358.0. uosc 5.13.0.
- Unmodified Syncplay 1.7.6 client and server, commit `993232ab095bb810593459bc705b3e6fc64ad161`, the same local copy as for v0.2.0. 1.7.6 is still the latest upstream release.
- Official test dependencies: Twisted 26.4.0, pyOpenSSL 26.4.0, cryptography 50.0.2, service-identity 26.1.0, pywin32 312.
- Reference media: 180 seconds, 320×180, 10 fps.

All results below were obtained with one DLL, SHA256 `137d7702f60556390af4ced4ed0348749c2d35e06838a9a3b08ec5ef14ad8043`, built from the release source at the start of the run and unchanged at its end. That is the DLL in the download. Builds are not byte-reproducible; a rebuild of the same source has a different hash, which is why it differs from the v0.2.0 DLL.

## Player launch arguments

The harnesses use the same mpv arguments as for [v0.2.0](validation-v0.2.0.md#player-launch-arguments). The two real UI path tests, run again for this release, add:

| Harness | mpv arguments |
| --- | --- |
| `ui_path.py` | `--load-scripts=no --config-dir=<isolated> --script=` for each of the four runtime files, `--input-conf=<isolated, ENTER cycle fullscreen> --input-ipc-server=<pipe> --force-window=yes --geometry=1000x680+50+50 --pause=yes --ao=null --script-opts=splay-language=zh-CN` with the test media; the uosc run adds `--script=<uosc 5.13.0>` and copies `tests/ui/fixtures/uosc-layout.conf` |
| `playlist_ui_path.py` | `--config-dir=<isolated, four runtime files installed> --load-scripts=yes --input-ipc-server=<pipe> --pause=yes --ao=null --idle=yes --force-window=yes --geometry=820x600+1080+50 --keep-open=no --script-opts=splay-language=zh-CN` with an observer script; the second player adds uosc 5.13.0 |

Every test that opens a real window starts mpv with a show-without-activating command. A 30 ms foreground-window sampler ran for the whole run (34,877 samples) and recorded one sample with an mpv window in the foreground, at the end of the uosc part of `tests/ui/overlay_review.py`. That review shows its window on screen without activating it, and the cause was not found: two further runs of the review under the sampler had no such sample. No other test window was seen in the foreground.

## Native checks

All nine suites passed: `core`, `reconnect`, `latency`, `autostart`, `room-policy`, `catchup`, `history`, `credentials` and `net`, and so did `tls-rejection` (a self-signed certificate is refused with no plaintext fallback), the interface translation coverage check `i18n`, and the vendored-source check. The credentials suite ran under the normal Windows user account because DPAPI is account-bound.

## Official-client interoperability

Seven suites passed against the unmodified official client and server with real mpv processes, with the same number of checks as for v0.2.0 and no official-client restarts.

| Suite | Checks passed |
| --- | --- |
| Local file | 76 |
| HTTP | 79 |
| Latency | 24 |
| All-ready autostart | 148 |
| Shared playlist | 46 |
| Official-server reconnect | 11 |
| Smooth catch-up | 38 |

The shared-playlist suite failed once in the full run: the step that sends an out-of-range index timed out waiting for the "out of range" error. A rejected command's error is delivered in one state message and the next regular state replaces it by design; the step looked only at the latest 100 ms snapshot and missed it when another state followed quickly. It passed on an immediate rerun, which was not counted. The two steps that check a rejected command (out-of-range index, oversized Unicode list) now look in the error record the observer already keeps, as the controlled-room permission steps of the same suite did. With that change the suite passed three runs in a row, 46 checks each, on the release DLL. The coverage of each suite is described for [v0.2.0](validation-v0.2.0.md#official-client-interoperability).

## Interface tests

These use real mpv with a mocked core or mocked protocol state. They do not substitute for the official-client tests.

- `tests/ui/smoke.py`: native and uosc entry points in a real window, plus the forms and playlist-forms fixtures. The forms fixture checks that six members of one room get nickname colours at least 0.12 apart in OKLab, that a person keeps one colour across chat, status lines, playback notices and message history, and that only the nickname is coloured in English word order.
- `tests/ui/latency_overlay.py` (including the coloured status-line segments and a malformed colour being ignored) and `tests/ui/history_restart.py` (three real DLL and Lua player processes).
- `tests/ui/overlay_review.py --mode all`: the overlay in native and uosc windows.
- `tests/ui/review.py` and `tests/ui/review.py --language en`: 18 captures each, in Chinese and in English.

## Real UI paths

`tests/integration/ui_path.py` and `playlist_ui_path.py` drive two real players with all four runtime files against the unmodified official server. They had failed since v0.1.1 because they were written for earlier menus; the tests were brought up to date without changes to the plugin or scripts. In the full run `ui_path.py` passed natively (44 checks) and with uosc and the fixture layout (43 checks), and `playlist_ui_path.py` passed with a native and a uosc player (34 checks). During the repair they passed three more native, two more uosc, four more native-plus-uosc and one `--native-only` run on a DLL built from the same source.

## Offline path and password prompt

`tests/integration/offline_path.py` ran with `--language zh-CN`, `--language en` and without the option (`auto`, which resolved to Simplified Chinese on this machine), 72 checks each, and `tests/integration/credential_ui_path.py` ran once, all against unmodified official servers protected by generated passwords. The coverage is as described for [v0.2.0](validation-v0.2.0.md#offline-path-and-password-prompt). Typed passwords still reach any mpv `--log-file`, as documented.

## Archive and source checks

`python tools/package.py` built `splay-windows-x64-v0.2.1.zip` from the validated DLL and this record. The plugin-only archive passed the independent allowlist and byte-for-byte input check, x64 DLL inspection, vendored-file SHA256 checks, license and notices inclusion, and ZIP checksum verification. Extracting the archive into an isolated configuration loaded all four runtime files, received native status, opened the panel and exited cleanly. Local Markdown links were checked.

The checksum of the archive checked here is in the release's `.sha256` file; the DLL inside it is the one named under Environment.

## Reproduce

See [Contributing](https://github.com/noxowin/splay/blob/v0.2.1/CONTRIBUTING.md) for dependencies. Outputs go into ignored `.local` directories. Run `tls-rejection` with the Python that has `cryptography` installed.

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
python tests/integration/ui_path.py
python tests/integration/ui_path.py --uosc .local/uosc/scripts/uosc --uosc-config tests/ui/fixtures/uosc-layout.conf
python tests/integration/playlist_ui_path.py
python tests/integration/interop.py
python tests/integration/interop.py --http
python tests/integration/latency_interop.py
python tests/integration/autostart_interop.py
python tests/integration/playlist_interop.py
python tests/integration/reconnect_official.py
python tests/integration/catchup_interop.py
python tools/package.py
python tools/verify_release.py --archive dist/splay-windows-x64-v0.2.1.zip --require-license
python tests/ui/package_smoke.py --archive dist/splay-windows-x64-v0.2.1.zip
```

## Not covered

- No TLS handshake with a public server was made for this release. The transport source is unchanged since v0.2.0, whose handshake with `syncplay.pl` is recorded there; the local `net` and `tls-rejection` checks ran.
- Nickname colour distances are computed in OKLab; colour-vision deficiencies were not simulated. Colours were judged by eye in one font and a 1100×620 window only. Green nicknames contrast less with the cyan of playback notices.
- The shared list is not published as a property, so the playlist UI path checks the number of imported entries, not that a new local file was added by its file name rather than its full path.
- Only the listed Windows, mpv and uosc versions. Other distributions, mpv.net, the minimum supported mpv, live streams and ad timelines are unverified. Browser launch and authentication chains remain excluded.
- The limits recorded for [v0.2.0](validation-v0.2.0.md#not-covered) still apply, except that the two UI path tests now run: catch-up was not watched or heard by a person, `auto` choosing English was checked only with a mocked state, passwords were typed over IPC rather than by a person, mixing runtime files from different versions is unsupported, weak-cipher rejection and address fallback have no reproducible test, and the limits from v0.1.0 remain.

中文：本版只改动 Lua 界面脚本，DLL 源码与 v0.2.0 相同、重新构建。区分真实官方互通与模拟协议的界面检查；昵称颜色未做色觉障碍模拟；本版未与公共服务器做 TLS 握手。上述环境之外不承诺普遍兼容。安装与功能说明见[中文指南](install.zh-CN.md)。
