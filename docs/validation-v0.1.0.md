# v0.1.0 validation

Recorded on 2026-10-22. Windows x64 release validation uses isolated player configurations, synthetic media and temporary local rooms. No personal player configuration, saved credentials or private media is included in the repository or download.

## Environment

- Native Windows, Python 3.12 and MinGW-Builds GCC 14.2.0 / UCRT.
- mpv `v0.41.0-dev-g41f6a6450`, uosc 5.13.0.
- Unmodified Syncplay 1.7.6 client/server, commit `993232ab095bb810593459bc705b3e6fc64ad161`. All 171 extracted files were compared with the pinned upstream archive; no missing or changed files. Archive SHA256: `c2f5ec81a873d506013e3d3069b5ae1d08df56a27e919284068f4fb104fd8c28`.
- Reference media: 180 seconds, 320×180, 10 fps. Browser launch/authentication chains are excluded at the user's request.

## Completed local checks

| Area | Coverage |
| --- | --- |
| Room policy | Default room-wide join/leave pause, List/State order, complete snapshot baseline, duplicate/foreign events, empty room position, controller authentication, cancellation of queued pauses and countdowns |
| Offset and playback | Fixed positive/negative local offset, inverse room position reports, finite/range checks, media reset, boundary hold before EOF, no clamped feedback, restoration to room playback |
| Native UI / uosc | Actual mpv loading and menu navigation, default off, compact popup bounds and overflow, Enter chat, transparent history, two consecutive sends, Esc, member details and settings |
| Forms and privacy | Stale callbacks, endpoint credential correlation, connection profile navigation, history bounds/deduplication, stable nickname colors and white bodies, precise duration differences, editable offset suggestions and stale-input guards |
| Preferences | Three real DLL/Lua player processes: room/danmaku mode and join/leave preferences saved/restored independently of connection profiles; connection history and blank-room handling retained |
| Overlay | Real native/uosc windows with mocked protocol state: duration colors/right edge, single-line tail truncation, latency signal colors independent of readiness, missing latency hidden, idle/pause visibility, timeline clicks, foreign menu/controls ownership |
| Scrolling chat | Real fps filter insertion/removal only after opt-in, existing and foreign filters preserved, room-mode restoration, playback/paused screenshots and console suppression. Subjective smoothness across GPUs/decoders is not claimed |

All seven native suites passed: core, room policy, reconnect, latency, autostart, history and credentials. The credentials suite ran under the normal Windows user account because DPAPI is account-bound; no cross-account test is claimed. History tests cover process restart, concurrent preference/profile merges, clear-with-preferences-preserved and corruption handling.

## Official-client interoperability

Six suites passed with the same final DLL: local-file playback, HTTP playback, latency, all-ready autostart, shared playlists and official-server reconnect. These use the unmodified official client/server with real mpv processes, not protocol doubles.

The local and HTTP cases cover late join, room-wide join/leave pause, empty-room position, bidirectional play/pause/seek/chat, rapid pause changes, positive/negative offsets, running-room boundary hold and recovery, controlled-room creation/authentication/permissions, manual reconnect, a 30-second paused heartbeat, media stop/reload and independent playback after server loss. HTTP metadata tests verify safe late titles and hidden URL fallbacks. Separate suites cover countdown cancellation, playlist permissions/wire limits, latency exchange and reconnect state recovery.

Validation found and fixed three issues before release: EOF unloading on extreme offsets, stale server watcher clocks during boundary holds, and a missing member-list request after creating a controlled room. The failing cases are retained as regression coverage.

Validated DLL SHA256: `4c38255572c147199cf36e6e3f059ede7a99ced018562b7ebe6ba531cb1d3a96`.

## Archive and source checks

The plugin-only archive passed an independent 19-file allowlist and byte-for-byte input check, x64 DLL inspection, eight vendored-file SHA256 checks, license/notices inclusion and ZIP checksum verification. Extracting the package into an isolated configuration successfully auto-loaded all four runtime files, received native status, opened the panel and exited cleanly. Source review found no private configuration, runtime history, credentials or downloaded executables among tracked/new files; local Markdown links and Python syntax checks passed.

GitHub builds run the seven native suites and archive checks on the matching source commit. See the [workflow runs](https://github.com/noxowin/splay/actions/workflows/windows.yml) for the remote result; local verification above is recorded separately.

## Reproduce

See [Contributing](https://github.com/noxowin/splay/blob/v0.1.0/CONTRIBUTING.md) for dependencies. Outputs go into ignored `.local` directories. UI fixtures use real mpv with mocked protocol state; they do not substitute for official-client tests.

```powershell
python tools/build.py build
python tools/check.py core
python tools/check.py room-policy
python tools/check.py reconnect
python tools/check.py latency
python tools/check.py autostart
python tools/check.py history
python tools/check.py credentials
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
python tools/verify_release.py --archive dist/splay-windows-x64-v0.1.0.zip --require-license
python tests/ui/package_smoke.py --archive dist/splay-windows-x64-v0.1.0.zip
```

## Limits

- Only the listed Windows/mpv/uosc versions are covered. Other distributions, mpv.net, minimum supported mpv, live streams and ad timelines are unverified.
- Duration equality does not establish identical content. Offset suggestions cannot compensate for different endings or multiple edits.
- All-ready countdown has no cross-client leader election; use one coordinator in a room. Room-wide pause still requires controller permissions in controlled rooms.
- Latency is a client's round trip to the server, with peer values self-reported. Unsupported clients have no latency signal.
- Network titles depend on player metadata. Unknown titles stay hidden; the plugin does not scrape websites. Media transfer and watched markers are not implemented.
- DPAPI storage is tied to the current Windows account; cross-account/device migration is unverified. Playlist following remains off initially, and unfamiliar network URLs require confirmation.
- Raising output cadence duplicates frames and can increase load. Hardware decode paths and smoothness on every display/GPU are not validated.

中文：本版区分真实官方互通与模拟协议的界面检查；上述环境之外不承诺普遍兼容。安装与功能说明见[中文指南](install.zh-CN.md)。
