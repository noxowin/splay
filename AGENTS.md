# splay collaboration notes

## Scope and status

- splay is an optional Syncplay-compatible extension for existing mpv installations, initially on Windows. A bundled player is a later phase.
- Implementation is now authorized by the user's 2026-10-13 request, following docs/implementation-plan.md. Never describe proposed behavior as implemented or tested without evidence.
- Work within the current user request. The roadmap is not blanket authorization to implement every milestone.
- The user authorized public publication on 2026-10-14 and selected GPL-3.0. Project-authored code is GPL-3.0-only; preserve the original licenses of vendored files. Do not change visibility as part of routine pushes or releases.

## Architecture constraints

- Keep protocol/synchronization logic separate from the mpv adapter and presentation layer.
- Prefer an in-process native plugin with a Lua interface. Verify the target mpv build before selecting implementation dependencies or a minimum version.
- uosc is optional. Provide an independent mpv interface and avoid relying on a particular distribution's LuaSocket or bundled scripts.
- Install only splay-owned files. Do not replace mpv.conf, input.conf, uosc.conf, or unrelated scripts.
- Joining synchronization must preserve the currently loaded media and caller-supplied playback parameters.
- Default to disconnected. Keep multiple player instances independent and avoid silently connecting all instances to the same room.
- Do not broadcast private media URLs or authentication parameters by default. Treat protocol text as data rather than executable mpv commands.

## Validation and reporting

- Use current upstream implementation plus a pinned reference version for protocol compatibility; the old Syncplay protocol article is incomplete.
- Before claiming a usable first release, test against an unmodified Syncplay server and the official client, with real mpv instances.
- Cover playback feedback loops, delayed/out-of-order state, loading/buffering, joining late, controlled-room permissions, disconnect/reconnect, and cleanup.
- Test native mpv and uosc paths separately; document exact versions, launch arguments, and untested integrations.
- Documentation-only changes need link/path and Git diff checks, not placeholder tests.
- Keep passwords, tokens, real private room settings, media URLs, and downloaded player binaries out of Git.

## Publication

- Preserve upstream attribution if code is later reused. A reference link does not grant permission to copy without complying with the source license.
- Do not tag a stable release or publish a ready-to-install download while only design documents exist.
- Report local commit, remote verification, and any incomplete authentication or publishing step accurately.
- Publish development previews as prereleases; do not imply stable or universal mpv compatibility. Include the project license, third-party notices, checksum and a matching source tag with binary releases.
