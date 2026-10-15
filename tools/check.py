"""Reproducible native checks. Python/compiler are development dependencies."""
from pathlib import Path
import argparse
import subprocess
import sys
from build import ROOT, default_compiler

parser = argparse.ArgumentParser()
parser.add_argument('suite', choices=['core', 'history', 'credentials', 'net', 'ui', 'ui-review', 'ui-history', 'tls-rejection'])
parser.add_argument('--compiler', default=default_compiler())
args = parser.parse_args()

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
elif args.suite in ('core', 'net', 'tls-rejection'):
    target = 'core' if args.suite == 'core' else 'net'
    output = ROOT / '.local' / ('session_test.exe' if target == 'core' else 'transport-test.exe')
    output.parent.mkdir(exist_ok=True)
    sources = ([ROOT/'tests/core/session_test.cpp', ROOT/'src/core/session.cpp'] if target == 'core'
               else [ROOT/'tests/net/driver.cpp', ROOT/'src/net/transport.cpp'])
    libraries = ['-lbcrypt'] if target == 'core' else ['-lws2_32', '-lsecur32', '-lcrypt32', '-lbcrypt']
    run([args.compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-static', '-pthread',
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
