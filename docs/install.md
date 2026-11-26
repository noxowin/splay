# Install and use splay v0.2.1 on Windows

**English** · [简体中文](install.zh-CN.md) · [README](https://github.com/noxowin/splay)

## Install or upgrade

1. Download [splay-windows-x64-v0.2.1.zip](https://github.com/noxowin/splay/releases/download/v0.2.1/splay-windows-x64-v0.2.1.zip) from the [v0.2.1 release](https://github.com/noxowin/splay/releases/tag/v0.2.1). Check its SHA256 against the published checksum.
2. Close mpv and locate its active configuration directory: commonly `%APPDATA%\mpv`, or `portable_config` beside `mpv.exe` for portable installations. Launchers may select another directory.
3. Copy **all four** files into that directory's `scripts` folder: `splay.lua`, `splay_core.dll`, `splay_overlay.lua`, `splay_playlist.lua`. Back up and replace existing splay files together.
4. Keep `mpv.conf`, `input.conf`, `uosc.conf` and other scripts. Optional non-secret defaults can be copied from [splay.conf.example](../script-opts/splay.conf.example) into `script-opts/splay.conf`. Never put passwords there.

Requires Windows x64 mpv with C plugins and Lua `mp.input`. uosc is optional. Python, LuaSocket and a separate Syncplay client are not required at runtime. Tested versions and coverage are in [validation](validation-v0.2.1.md). GitHub's Source code ZIP does not contain a compiled DLL.

## Connect and navigate

Open media normally, then press **Shift+s** or click the Sync icon. Each new player starts with splay disabled; enable it, fill in a room and connect manually. Initial server: `syncplay.pl:8999`; nickname: `splayuser`; room: empty. Separate players keep separate connections.

Joining an ordinary room name creates it if needed; an existing name joins that room. Connection profiles can be filled, joined, edited, named or deleted. Joining with a saved profile waits for that server's saved credentials. The connected menu provides room functions, shared playlists and **Settings**; members and local time offset are under room functions.

Shift+s is an ordinary binding; `input.conf` can override it. To bind explicitly, use `SHIFT+s script-message-to splay splay-open` (append `uosc` for its menu). This conflicts with mpv's uppercase S screenshot binding, so choose the action you prefer.

## Chat and display

- **Enter** opens quick chat when connected with media loaded; Enter sends and Esc cancels. Other menus and input fields keep their own keys.
- **Shift+h**, or Settings → message history, opens a transparent full-window console over the video. Enter sends and keeps the input open; Page Up/Down or the mouse wheel browse history; Esc closes it. History keeps the latest 300 messages in this process, including chat and room/playback events. It is not written to disk. Room changes, disconnecting or disabling splay close the console/input.
- Settings switches between room chat and scrolling chat. Each nickname keeps one color and message text stays white; people in the same room get clearly different colors first, and nicknames in the top-left status lines and in message history use the same color. The selected mode is remembered independently of connection profiles when history is enabled. Scrolling text defaults to 15% larger; room-chat text is unchanged.
- **Smoother scrolling during playback** is off by default. It raises video output cadence with a labeled fps filter while scrolling chat is active, up to 60 fps (or a lower display refresh rate). It duplicates frames rather than interpolating motion and can increase playback load. Turning it off removes splay's own unchanged filter; external filter changes or unsupported output produce a notice.
- **Interface language**: Simplified Chinese or English. Settings → **语言 / Language** cycles Auto → 简体中文 → English and applies immediately. Auto follows the Windows display language: any Chinese variant uses Simplified Chinese, everything else English. `language=auto|zh-CN|en` in `splay.conf` sets the default; with history enabled the menu choice is remembered like the chat mode and takes precedence. The password prompts and the room panel follow it. Messages already in the history keep the language they were recorded in. With an older `splay_core.dll` Auto stays in Chinese and the menu choice is not saved; replace all four files together.
- Short messages appear at top left, room/member information at top right. While playing, the room panel follows mouse-idle/cursor settings; it remains visible while paused. Settings can hide status, buttons or room information.

## Room behavior and readiness

**Join pause and leave pause are on by default.** Joining a room requests a room-wide pause; a member leaving the same room, including switching rooms, also requests a pause. Controlled-room playback remains subject to controller permissions. Both options can be disabled in Settings and are remembered independently of connection profiles. These actions preserve the loaded media and its playback arguments.

**All-ready autostart is on by default.** Once at least two members have media and explicitly report ready, the local player is paused, seekable, at 1× and not buffering, a **five-second countdown** can start. A controlled room additionally requires controller authentication. Settings can disable it; the connection/room boundary reapplies your current preference rather than resetting each state update.

Changing readiness, membership/media, buffering, local playback operations or remote playback cancels a pending countdown. A ready phase fires once; manually pausing does not repeatedly restart it. Withdraw/reapply readiness or explicitly restart the strategy for another attempt. Use one coordinator per room: there is no countdown leader election between clients. Duration equality is not an autostart requirement. Starting playback yourself marks you ready; remote playback does not.

## Duration and local offset

Media comparison uses valid **raw duration values**: equal is green, different is red, unknown/self is gray. There is no 2.5-second tolerance or filename-based “likely same media” verdict. Only a mismatch adds a difference line. Colors are independent of readiness and latency, and equal duration does not prove identical content.

Room functions and member details offer **local time offset**: enter positive/negative seconds, adjust by one second or reset. Local time = room time + offset; a longer local intro usually needs a positive offset. Changing it moves only your player and cancels its countdown; it does not broadcast a room seek or alter duration comparison. Loading another media clears it; reconnecting or changing rooms with the same media retains it. It is not saved across processes.

Choose a member to prefill **local duration − their duration**, edit the value and confirm. It replaces the current offset rather than adding to it; changed connection/member/media information invalidates a stale suggestion. Different endings or multiple edits cannot be solved by a single fixed offset: align against the actual picture or use matching media.

If an offset places your player outside the available media, it pauses locally before reaching EOF and keeps the room clock. Reset the offset or let the room reach the available segment to resume following. This local boundary pause does not pause the room or report the clamped position to others.

## Shared playlists and network media

The room playlist is separate from mpv's local queue. Receiving it or joining a room does not load another item. Ordinary room members and controlled-room controllers can edit/select items; other controlled-room members may only follow.

Add local filenames, bind an item to a local file, import the local queue, sort or remove items. Only local filenames are shared, not full paths. Sharing the current HTTP(S) address or importing network queue entries requires an explicit confirmation before sending complete addresses to the room. Do not share a private or authenticated URL unintentionally. Displayed addresses omit credentials/query parameters; the confirmed shared address itself is complete.

Local matching uses the known queue/current directory or an explicit binding; it does not recursively scan disks or automatically open remote absolute paths or other protocols. **Local following is off by default**, and resets on room changes. Enable it to follow room selections and advance at end of media, or explicitly play the current room item locally. Unfamiliar HTTP(S) addresses require individual confirmation before opening; an identical address already in your local queue or confirmed in this process can be reused.

Limits: 250 entries, 10,000 Unicode characters total, and the server's 16 KiB protocol-line limit including encoding and usernames. Room persistence depends on the server; local bindings last only for this process. Playlists do not transfer media, and watched markers are not implemented.

## History, passwords and reconnecting

`splay-history.json` stores non-secret fields, named connection profiles and the chat/join/leave/language preferences. History management can remove profiles, field suggestions or all non-password history without disconnecting. Clearing connection history does not remove separately stored passwords. `history_enabled=no` disables history reads/saves; saved history otherwise takes precedence over initial defaults.

Server and operator passwords are typed into mpv's own input box (the console), where they are **visible in clear text while typed**; check who can see the screen first. Each prompt has its own input history that is never offered again with the Up key and never written to disk, and passwords are not copied into profiles. Server passwords are remembered by server/port in `splay-credentials.json`, encrypted with the current Windows user's DPAPI. The typed password passes through the Lua interface and one mpv command on its way to the native core, so a debug-level mpv log contains it: `--msg-level=all=debug` (or `trace`) and **any `--log-file`**, which records at debug level by default, write the password in plain text. Do not share such logs. Without a video window (for example `--vo=null`), the console draws in the terminal and the typed text appears on standard output at the default level. `remember_password=no` uses process memory only and leaves existing encrypted files in place. Saved credentials are not portable across Windows accounts/computers. Storage/decryption failures are reported rather than silently retried with an empty password. Controller passwords are not remembered. Do not publish these files or private logs.

Automatic reconnect is on by default for connections you initiated. Temporary failures retry after 2, 5, 10, 30 and 30 seconds; disconnecting, disabling or canceling stops retries. Authentication/protocol rejection and certificate failure do not retry or downgrade TLS. Reconnecting retains media and its arguments; it does not restore controller authorization, readiness or playlist-follow permission. A new player still never auto-connects.

Latency display/sharing is on by default (`latency_enabled=yes`). Values measure each client's round trip to the server, not peer-to-peer latency. Peers must report supported metadata; missing values hide the signal indicator and old values may be marked stale. Sharing runs about every ten seconds while connected, without IPs or media URLs; without media there may be no file metadata to attach. Settings can stop sharing. Defaults for reconnect/autostart/latency and display may be set in `splay.conf`; unlike chat/join/leave/language preferences, their menu changes apply to the current process.

## Controlled rooms, TLS and uosc

Create/join a Syncplay controlled room and authenticate as controller to restrict room playback and playlist edits. A base room name is limited to 21 characters; a controller password uses the `AB-123-456` format. Others join the full controlled-room name returned by the server. Server and controller passwords are typed into the mpv input box and are visible while typed.

**Smooth catch-up is on by default**: when this player is 1.5 to 4 s ahead of the room, it plays at 0.95× until level instead of jumping back; a lead over 4 s or a delay over 1.5 s is still corrected by seeking. A short notice appears when it starts and ends. Turn it off in Settings → Smooth catch-up, or with `smooth_catchup=no` in `splay.conf`. Quitting mpv while slowed does not save 0.95× into watch-later. A non-1× speed you set yourself suspends synchronization, and splay leaves it alone; loading/buffering operations are not broadcast as user actions. Unseekable media cannot be aligned. Real browser authentication chains, live streams and ad timelines have limited coverage; check [validation](validation-v0.2.1.md).

TLS `prefer` permits plaintext only when the server explicitly lacks TLS; `require` rejects plaintext; `off` disables TLS. Handshake/certificate failure never downgrades. The current transport uses Windows Schannel TLS 1.2 with weak cipher algorithms refused, and system trust with cached certificate-chain checks.

Native mpv menus work independently of uosc. Set `ui=uosc` or send `script-message-to splay splay-open uosc` for its menu. When a readable controls layout exists, splay adds `button:splay` and a connected chat button for this process, preserving other buttons and leaving `uosc.conf` untouched. Otherwise it uses standalone icons.

## Remove splay

Close mpv and remove only its four runtime files and any splay-only configuration/key/button entries you added. Optionally remove `splay-history.json`, `splay-credentials.json` and their `.lock` files. Keep the rest of your player configuration.
