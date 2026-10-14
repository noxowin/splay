"""Install the final ZIP into an isolated config; load the real DLL and Lua."""
from pathlib import Path
import subprocess
import zipfile

root = Path(__file__).resolve().parents[2]
archive = root / 'dist/splay-windows-x64-preview.zip'
config = root / '.local/package-smoke'
config.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as bundle:
    for item in bundle.infolist():
        target = (config / item.filename).resolve()
        assert target.is_relative_to(config.resolve()), item.filename
    bundle.extractall(config)
args = [str(root / '.local/mpv/runtime/mpv.exe'), '--config-dir=' + str(config),
        '--idle=yes', '--force-window=yes', '--ao=null', '--msg-level=all=debug',
        '--script=' + str(root / 'tests/ui/package_driver.lua')]
result = subprocess.run(args, cwd=root, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, timeout=10)
text = result.stdout.decode('utf-8', errors='replace')
(config / 'smoke.log').write_text(text, encoding='utf-8')
assert result.returncode == 0, text
assert 'Lua error' not in text and 'stack traceback' not in text, text
assert 'PACKAGE_SMOKE_COMPLETED' in text, text
assert 'PACKAGE_NATIVE_OPEN true' in text, text
assert '[splay_core] Destroying client handle' in text, text
assert '[splay] Destroying client handle' in text, text
assert 'args="splay-state"' in text, text
assert "Can't find script 'splay_core'" not in text, text
assert "Can't find script 'splay'" not in text, text
print('Package coexistence: real packaged Lua + DLL auto-loaded, core status received, native panel opened, clean exit')
print(config / 'smoke.log')
