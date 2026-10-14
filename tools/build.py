"""Build the Windows mpv C plugin; Python is a developer dependency only."""
from pathlib import Path
import argparse
import os
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def default_compiler():
    return os.environ.get('CXX') or shutil.which('g++') or r'C:\Program Files\mingw64\bin\g++.exe'


def build(compiler):
    sources = sorted(p for folder in ('core', 'mpv', 'net') for p in (ROOT/'src'/folder).glob('*.cpp'))
    if not sources:
        raise SystemExit('No native source files found')
    output = ROOT/'build'/'splay_core.dll'
    output.parent.mkdir(exist_ok=True)
    command = [compiler, '-std=c++17', '-O2', '-Wall', '-Wextra', '-shared',
               '-static-libgcc', '-static-libstdc++', '-static', '-pthread',
               '-DWIN32_LEAN_AND_MEAN', '-DNOMINMAX',
               '-I'+str(ROOT/'src'), '-I'+str(ROOT/'third_party'),
               *map(str, sources), '-o', str(output),
               '-lws2_32', '-lsecur32', '-lcrypt32', '-lbcrypt']
    subprocess.run(command, cwd=ROOT, check=True)
    print(output)
    return output

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', nargs='?', choices=['build', 'package', 'test'], default='build')
    parser.add_argument('--compiler', default=default_compiler())
    args = parser.parse_args()
    if args.command == 'test':
        subprocess.run([sys.executable, str(ROOT/'tests'/'ui'/'smoke.py')], check=True)
    else:
        build(args.compiler)
        if args.command == 'package':
            subprocess.run([sys.executable, str(ROOT/'tools'/'package.py')], check=True)
