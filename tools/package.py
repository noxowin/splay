"""Produce a plugin-only archive, with an explicit allowlist."""
from pathlib import Path
import zipfile
import hashlib

ROOT = Path(__file__).resolve().parents[1]
files = {
    'scripts/splay_core.dll': ROOT/'build/splay_core.dll',
    'scripts/splay.lua': ROOT/'scripts/splay.lua',
    'script-opts/splay.conf.example': ROOT/'script-opts/splay.conf.example',
    'INSTALL.txt': ROOT/'packaging/INSTALL.txt',
    'docs/install.md': ROOT/'docs/install.md',
    'docs/validation.md': ROOT/'docs/validation.md',
    'licenses/SOURCES.json': ROOT/'third_party/SOURCES.json',
}
for path in sorted((ROOT/'third_party').rglob('*LICENSE*')):
    if path.is_file():
        files['licenses/'+str(path.relative_to(ROOT/'third_party')).replace('\\','/')] = path
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
    if (ROOT/name).is_file(): files[name] = ROOT/name
for path in files.values():
    if not path.is_file(): raise SystemExit('Missing package input: '+str(path))
destination = ROOT/'dist'/'splay-windows-x64-preview.zip'
destination.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, path in files.items(): archive.write(path, name)
digest = hashlib.sha256(destination.read_bytes()).hexdigest()
checksum = destination.with_name(destination.name + '.sha256')
checksum.write_text(digest + '  ' + destination.name + '\n', encoding='ascii')
print(destination)
print(checksum)
