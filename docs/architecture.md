# Architecture and interfaces

**English** · [简体中文](architecture.zh-CN.md)

splay runs inside an existing mpv process. A C++17 native plugin handles the protocol and playback synchronization, Lua provides the interface, and uosc is an optional integration. The DLL uses the host API through `MPV_CPLUGIN_DYNAMIC_SYM` and does not link a second libmpv. See [Contributing](../CONTRIBUTING.md) for the build.

This document describes the current main branch. Differences from the released v0.1.0 are listed under the unreleased section of the [changelog](../CHANGELOG.md). The checks actually run for v0.1.0, and what they do not cover, are in the [validation record](validation-v0.1.0.md).

## Modules

| Location | Responsibility |
| --- | --- |
| `src/core/` | Syncplay protocol, room permissions and synchronization decisions; non-secret connection history and Windows DPAPI credential storage |
| `src/net/` | Winsock connection, STARTTLS and Schannel TLS. The transport thread only invokes a callback injected by the adapter, which calls the thread-safe `mpv_wakeup`; it makes no other mpv call and this directory includes no mpv header |
| `src/mpv/` | Plugin entry point, playback property sampling, applying remote state, and the Lua message bridge |
| `scripts/splay.lua` | Main menu, connection forms, history selection and the optional uosc adapter |
| `scripts/splay_overlay.lua` | On-screen icons, transient messages and room status |
| `scripts/splay_playlist.lua` | Shared playlist menu, local file matching, explicit following and advancing at end of file |

The core and the interface exchange JSON through `script-message-to`. History and credentials are stored separately, each with a file lock and atomic replacement. The native password dialog runs on its own thread. Interactive secrets are consumed by the native adapter; Lua receives only the outcome and a short-lived credential token, never the plaintext.

## Automation interface

Send `script-message-to splay splay-command <JSON>`. The main script applies the enabled state in one place. The table lists the common `action` values and their parameters; the [Lua entry point](../scripts/splay.lua) and the [native adapter](../src/mpv/plugin.cpp) define the complete behavior.

| action | Parameters and purpose |
| --- | --- |
| `status` / `disconnect` | Query the state / disconnect |
| `connect` | `host`, `port`, `username`, `room`, `password`, `tls`; automation must choose `remember_password` / `use_saved_password` / `auto_reconnect` explicitly |
| `room` / `ready` | `room` is the room name; `ready` is a boolean |
| `chat` | `text` is the message body |
| `authenticate` | `password` is the operator password, not the server connection password |
| `create-room` | `room`, `password`; creates a controlled room |
| `playlist-set` | `files` is the complete list, subject to server capabilities and length limits |
| `playlist-index` | `index` is zero-based, subject to room control permissions |
| `latency` | `enabled` is a boolean controlling the optional RTT display and metadata sharing |
| `autostart` | `enabled` is a boolean; optional `delay` is an integer from 3 to 30 seconds (the interface always uses 5). The all-ready countdown policy for this connection |
| `autostart-cancel` | Cancels the current countdown; it can run again only in the next readiness phase or after being explicitly re-enabled |
| `room-policy` | `pause_on_join` / `pause_on_leave` are booleans for pausing when joining and when a member of the same room leaves; on by default, subject to controlled-room permissions |
| `set-offset` | `seconds` is a finite number within ±86400; local time = room time + offset, and the state returns `time_offset` |

The native core returns a versioned state as `splay-state`, covering connection, room, members, readiness and playlist, and notifies the interface of events through `splay-event`. The direct `splay_core` entry point is for the internal bridge and tests. Automation should use protected local IPC and avoid logging commands that contain a password.

## Behavior boundaries

- Every new process starts disabled and does not connect on its own. Enabling splay or joining a room does not reload the video or rewrite the caller's media arguments.
- With no connection, no pending reconnect, no password prompt and no local time offset, the core only waits for mpv events and does not sample playback properties. A connect or offset command samples once and then resumes sampling every 100 ms. Each received protocol line carries the arrival time recorded on the transport thread; latency and the room clock are computed from it.
- Synchronization covers pause and position. Loading and buffering are not broadcast as deliberate actions. Synchronization is suspended at playback speeds other than 1x. Automatic reconnect works only after an explicit connect grants it, with a bounded number of retries and connection generations kept apart.
- The reported media state is a safe local filename or a trusted network media title, the duration, and size 0. Unknown names stay hidden; full paths and media URLs are never broadcast. Explicitly adding or importing into the shared playlist sends network addresses only after separate confirmation, and matched media is loaded only on an explicit selection or with following turned on.
- Unknown HTTP(S) addresses need confirmation one by one. Remote absolute paths and other protocols are never loaded automatically. The shared playlist does not transfer media.
- TLS uses Windows Schannel, TLS 1.2 only, with `SCH_USE_STRONG_CRYPTO` refusing weak algorithms such as RC4, DES, export-grade and null ciphers. `prefer` allows plaintext only when the server states that it does not support TLS; a handshake or certificate failure does not downgrade, and `require` refuses plaintext.
- Only splay's own files are managed. uosc controls are extended in the current process only, without changing configuration on disk. Protocol text is handled as data.

The all-ready countdown needs a complete member snapshot, at least two members in the room, explicit readiness and media, a local player that can synchronize, and, in a controlled room, authentication on this connection. The core turns it off on a room change and on reconnect. At each successful connect or room-change boundary Lua submits the five-second policy once, according to the local preference (on by default; turning it off manually holds), rather than resetting the timer on every state refresh. When the timer expires the conditions are checked again and the existing playback state protocol is used; no leader election is added to the network. The `autostart` state contains `enabled`, `delay`, `pending`, `remaining`, `reason` and `participants`.

Pausing on join, and when a member of the same room leaves or changes room, is on by default. It requests a room-wide pause through the existing playback permissions and does not bypass operator restrictions in a controlled room. `chat_mode`, `pause_on_join` and `pause_on_leave` are saved in the non-secret history, independently of connection profiles. Other menu switches apply to the current process only; `splay.conf` can set their defaults at startup.

A member's `media` in Lua is data derived locally for display: duration, the source of the name, and the strict duration comparison. It is not sent back to the server as protocol data and plays no part in countdown eligibility.

Durations are compared as valid raw seconds, with no tolerance and no inference from names. `media.check` is independent of readiness and of latency colors: `duration_match` is green, `duration_mismatch` is red, `unknown` and `self` are grey. The right column shows an extra note only when durations differ, giving the difference. Green means equal duration only; it does not show that the files are the same. The offset menu can prefill a candidate from a chosen member's duration difference (local duration minus theirs). After confirmation in an editable input it uses the ordinary `set-offset` command. It does not change the comparison, and is neither applied directly nor added to the current offset. The candidate is checked again against the connection, member and media snapshot when submitted.

The local time offset is converted in one place in the core: outgoing positions have it subtracted and incoming positions have it added. Changing the offset only repositions the local player and cancels the local countdown; it does not broadcast a seek to the room. When the target falls outside the media, the local player is paused inside the boundary and the authoritative room clock is kept. Heartbeats keep reporting the room clock and the room's pause state, never the clamped local position or the local pause, so that the official server's watcher timestamps do not hold the room back. Following resumes when the offset returns to zero or the room reaches a playable part, and a seek by the user still goes through the usual permission checks. The offset is cleared on a media change and kept across a room change or reconnect for the same media. It is not saved, and it changes neither the raw duration nor the comparison result. It compensates for one fixed time difference; versions with several different cuts need adjusting section by section, or the same version.

`state.settings` passes display, room information and chat mode preferences to the overlay. The full-window history is drawn by the main Lua script with ASS and keeps accepting chat through `mp.input`; while it is open, `user-data/splay-console-open` hides splay's other overlays and buttons. At most 300 messages stay in the process. Disconnecting, changing room or disabling splay closes the input, so an old draft cannot be sent to a new room.

The history layer draws no full-screen background; outlined text keeps it readable over video. The main script assigns a color to each complete nickname, caches it and passes it with events to the overlay, so history, room chat and scrolling chat show a nickname in the same color while the message body stays white. The first 24 distinct nicknames get distinct colors, later ones may reuse them, and the cache holds at most 1024 nicknames.

Scrolling chat uses its own ASS layer with cached text styles. Positions are refreshed only while messages are active, and animation frames neither rebuild the room panel nor broadcast geometry. It follows the approach of the [uosc_danmaku render module](https://github.com/Tony15246/uosc_danmaku/blob/main/modules/render.lua) in updating text coordinates and layers explicitly, with its own bounded tracks and cleanup for live chat, and does not take over other danmaku plugins.

During playback mpv normally draws the OSD with video frames, and can redraw it independently while paused, so raising the Lua animation rate alone cannot make text move more often than a low-frame-rate video is shown. Video filters are left alone by default. With `danmaku_smooth` explicitly enabled, scrolling chat mode may add an fps filter under its own label to raise the output rate to at most 60 frames per second, or to the display's rate on a slower screen. This repeats frames rather than interpolating motion, and adds processing load. Leaving the mode or disabling the plugin removes only the node splay added and only if it still matches; the rest of the filter chain is not replaced. If adding it fails, or something else changes it, a notice is shown and it is not retried on every state refresh. Titles are measured with cached actual ASS glyph widths, so no expensive measurement runs in an animation frame.

The current interoperability baseline is unmodified Syncplay 1.7.6. The real tests and what they do not cover are in the [validation record](validation-v0.1.0.md); following official updates is described in [Upstream compatibility](upstream-compatibility.md).

## References and sources

- [mpv](https://github.com/mpv-player/mpv): [C plugins](https://mpv.io/manual/stable/#c-plugins) and the host interface.
- [Syncplay 1.7.6](https://github.com/Syncplay/syncplay/tree/v1.7.6): protocol and interoperability reference. This project does not bundle the official client implementation.
- [uosc](https://github.com/tomasklaen/uosc) and its [Menu API](https://github.com/tomasklaen/uosc/wiki/Menu-API): optional interface integration.
- Integration and build references: [mpv-config](https://github.com/dyphire/mpv-config/), [mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake), [mpv-winbuild](https://github.com/dyphire/mpv-winbuild), [uosc_danmaku](https://github.com/Tony15246/uosc_danmaku).

The third-party files actually distributed with the source, and their pinned hashes, are listed in [SOURCES.json](../third_party/SOURCES.json); their licenses are in [Third-party notices](../THIRD_PARTY_NOTICES.md). A link to a reference project does not mean its code is part of this project.
