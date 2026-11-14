"""Reproducible native checks. Python/compiler are development dependencies.

The synchronization core suites (core, reconnect, latency, autostart,
room-policy) are portable C++ and also run on Linux; the others use Windows APIs.
"""
from pathlib import Path
import argparse
import os
import subprocess
import sys
from build import ROOT, default_compiler

parser = argparse.ArgumentParser()
parser.add_argument('suite', choices=['core', 'reconnect', 'latency', 'autostart', 'room-policy', 'history', 'credentials', 'net', 'ui', 'ui-review', 'ui-history', 'tls-rejection'])
parser.add_argument('--compiler', default=default_compiler())
parser.add_argument('--sanitize', action='store_true',
                    help='Build the portable core suites with AddressSanitizer and UndefinedBehaviorSanitizer (not MinGW)')
args = parser.parse_args()

WINDOWS = os.name == 'nt'
CORE_SUITES = {'core':'session_test.cpp','reconnect':'reconnect_test.cpp','latency':'latency_test.cpp',
               'autostart':'autostart_test.cpp','room-policy':'room_policy_test.cpp'}
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
elif args.suite in ('core', 'reconnect', 'latency', 'autostart', 'room-policy', 'net', 'tls-rejection'):
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
