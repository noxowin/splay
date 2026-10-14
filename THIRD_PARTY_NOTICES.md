# Third party notices

Project-authored splay code is licensed under GNU GPL version 3 only
(`GPL-3.0-only`); see the root `LICENSE`. Copyright (C) 2026 noxowin and
splay contributors. Vendored components retain the following original licenses.

- nlohmann/json 3.12.0: MIT license, `third_party/json/LICENSE.MIT`.
- mpv client API header 0.41.0: ISC license, `third_party/mpv/LICENSE.ISC`. The header retains its original notice.

The native DLL also statically links runtime code supplied by the compiler:

- MinGW-w64 runtime v12: component copyright, permissions and disclaimers are
  preserved in `third_party/runtime/LICENSE.MinGW-w64-runtime.txt`, including
  the MinGW-w64, David M. Gay/Lucent, Sun and other notices provided upstream.
- GCC 14.2.0 libgcc and libstdc++: Copyright Free Software Foundation, Inc. and
  the respective upstream contributors; GPL version 3 or later with the GCC
  Runtime Library Exception 3.1. Full texts are preserved in
  `third_party/runtime/LICENSE.GCC-GPL-3.0.txt` and
  `third_party/runtime/LICENSE.GCC-runtime-exception.txt`. The exception applies
  to these runtime components; splay-authored code remains GPL-3.0-only.
- winpthreads (MinGW-w64 v12): Copyright (c) 2011 mingw-w64 project and
  (C) 2010 Lockless Inc.; MIT and BSD notices are preserved in
  `third_party/runtime/LICENSE.winpthreads.txt`. These notices cover
  POSIX-thread MinGW-w64 builds, including MSYS2 UCRT64 CI builds. The retained
  preview2 DLL was built with MinGW-Builds GCC 14.2.0's Win32 thread model;
  its symbol table contains no pthread symbols, so this notice does not assert
  that the retained DLL contains winpthreads. CI records its actual compiler
  version; a future runtime/toolchain update must recheck these notices.

The runtime notices are unmodified texts from the fixed upstream versions and
were compared with the release compiler's supplied license files. The
MinGW-w64 upstream notice additionally preserves the 2011-2013 overall
copyright years absent from that compiler distribution's copy. The other
three texts match the compiler copies after line-ending normalization.
Compiler executables, unrelated build-tool libraries, mpv and Syncplay are
not included in the plugin archive. Windows system DLLs are provided by the OS.

Pinned source URLs, provenance and SHA-256 hashes are recorded in
`third_party/SOURCES.json`. In a binary ZIP, the same notices are under
`licenses/json/`, `licenses/mpv/` and `licenses/runtime/`; its manifest is
`licenses/SOURCES.json`.

No upstream Syncplay implementation code is bundled; interoperability was
independently implemented against Syncplay 1.7.6.
