"""Reproducible native checks. Python/compiler are development dependencies.

The synchronization core suites (core, reconnect, latency, autostart,
room-policy, catchup) are portable C++ and also run on Linux; the others use Windows APIs.
The lua suite only parses the scripts and runs wherever LuaJIT or luac is installed.
The i18n suite statically checks interface translation coverage and needs only Python.
"""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys
from build import ROOT, default_compiler

parser = argparse.ArgumentParser()
parser.add_argument('suite', choices=['core', 'reconnect', 'latency', 'autostart', 'room-policy', 'catchup', 'history', 'credentials', 'net', 'ui', 'ui-review', 'ui-history', 'tls-rejection', 'lua', 'i18n'])
parser.add_argument('--compiler', default=default_compiler())
parser.add_argument('--sanitize', action='store_true',
                    help='Build the portable core suites with AddressSanitizer and UndefinedBehaviorSanitizer (not MinGW)')
parser.add_argument('--lua', help='LuaJIT or luac executable for the lua suite; default: first found on PATH')
args = parser.parse_args()

WINDOWS = os.name == 'nt'
CORE_SUITES = {'core':'session_test.cpp','reconnect':'reconnect_test.cpp','latency':'latency_test.cpp',
               'autostart':'autostart_test.cpp','room-policy':'room_policy_test.cpp','catchup':'catchup_test.cpp'}
if args.suite == 'lua':
    # Parse only: a syntax error is caught here instead of when a player loads
    # the script. mpv's Windows builds use LuaJIT, so prefer it.
    tool = args.lua or shutil.which('luajit') or shutil.which('luac5.1') or shutil.which('luac')
    if not tool:
        raise SystemExit('The lua suite needs luajit or luac on PATH, or --lua')
    parse = [tool, '-bl'] if 'luajit' in Path(tool).name.lower() else [tool, '-p']
    files = sorted(path for folder in ('scripts', 'tests') for path in (ROOT/folder).rglob('*.lua'))
    if not files:
        raise SystemExit('No Lua files found')
    # The parser prints file, line and reason itself; report every bad file.
    failed = [path for path in files
              if subprocess.run([*parse, str(path)], cwd=ROOT, timeout=60, stdout=subprocess.DEVNULL).returncode]
    if failed:
        raise SystemExit('Lua syntax errors in: ' + ', '.join(str(path.relative_to(ROOT)) for path in failed))
    print(f'Lua syntax: {len(files)} files parsed with {Path(tool).name}')
    raise SystemExit(0)
if args.suite == 'i18n':
    subprocess.run([sys.executable, str(ROOT/'tests/ui/i18n_coverage.py')], cwd=ROOT, check=True, timeout=60)
    raise SystemExit(0)
if not WINDOWS and args.suite not in CORE_SUITES:
    raise SystemExit(f'The {args.suite} suite uses Windows APIs; only the core suites run on this platform')
if args.sanitize and (WINDOWS or args.suite not in CORE_SUITES):
    raise SystemExit('--sanitize applies to the portable core suites on a non-MinGW compiler')

def run(command):
    subprocess.run(list(map(str, command)), cwd=ROOT, check=True, timeout=180)

if args.suite == 'credentials':
    output=ROOT/'.local/credentials-test.exe'
    output.parent.mkdir(exist_ok=True)
    run([args.compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-static', '-pthread', '-municode',
         '-DWIN32_LEAN_AND_MEAN', '-DNOMINMAX', '-I'+str(ROOT/'src'), '-I'+str(ROOT/'third_party'),
         ROOT/'tests/credentials/driver.cpp', ROOT/'src/core/credentials.cpp', '-o', output, '-lcrypt32'])
    run([sys.executable,ROOT/'tests/credentials/test_credentials.py',output])
elif args.suite == 'history':
    output=ROOT/'.local/history-test.exe'
    output.parent.mkdir(exist_ok=True)
    run([args.compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-static', '-pthread', '-municode',
         '-DWIN32_LEAN_AND_MEAN', '-DNOMINMAX', '-I'+str(ROOT/'src'), '-I'+str(ROOT/'third_party'),
         ROOT/'tests/history/driver.cpp', ROOT/'src/core/history.cpp', '-o', output])
    run([sys.executable,ROOT/'tests/history/test_history.py',output])
elif args.suite in (*CORE_SUITES, 'net', 'tls-rejection'):
    target = 'core' if args.suite in CORE_SUITES else 'net'
    case = CORE_SUITES.get(args.suite)
    output = ROOT / '.local' / (Path(case).stem+('.exe' if WINDOWS else '') if case else 'transport-test.exe')
    output.parent.mkdir(exist_ok=True)
    sources = ([ROOT/'tests/core'/case, ROOT/'src/core/session.cpp'] if target == 'core'
               else [ROOT/'tests/net/driver.cpp', ROOT/'src/net/transport.cpp'])
    libraries = ['-lws2_32', '-lsecur32', '-lcrypt32', '-lbcrypt'] if target == 'net' else ['-lbcrypt'] if WINDOWS else []
    # Static linking keeps Windows test executables independent of the MinGW
    # runtime DLLs; sanitizer runtimes are shared and report every finding as fatal.
    # GCC's sanitizer instrumentation raises false maybe-uninitialized
    # warnings inside libstdc++ <regex>; that warning stays on in normal builds.
    mode = (['-O1', '-g', '-fno-omit-frame-pointer', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
             '-Wno-maybe-uninitialized']
            if args.sanitize else ['-O2', '-static'] if WINDOWS else ['-O2'])
    run([args.compiler, '-std=c++17', *mode, '-Wall', '-Wextra', '-pthread',
         '-DWIN32_LEAN_AND_MEAN', '-DNOMINMAX', '-I'+str(ROOT/'src'),
         '-I'+str(ROOT/'third_party'), *sources, '-o', output, *libraries])
    if target == 'core':
        run([output])
    else:
        script = 'test_tls_rejection.py' if args.suite == 'tls-rejection' else 'test_transport.py'
        run([sys.executable, ROOT/'tests/net'/script, output])
else:
    script={'ui-review':'review.py','ui-history':'history_restart.py'}.get(args.suite,'smoke.py')
    run([sys.executable, ROOT/'tests/ui'/script])
