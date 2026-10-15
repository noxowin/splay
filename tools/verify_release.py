"""Check vendored bytes and a plugin-only package without external dependencies."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class VerificationError(Exception):
    """A source or release artifact failed verification."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_sources(root):
    manifest = json.loads((root / 'third_party/SOURCES.json').read_text(encoding='utf-8'))
    records = manifest.get('files')
    require(isinstance(records, list) and records, 'SOURCES.json must list vendored files')
    recorded = set()
    for record in records:
        require(isinstance(record, dict), 'Invalid source record')
        name, digest = record.get('path'), record.get('sha256')
        require(isinstance(name, str), 'Source path must be a string')
        path = PurePosixPath(name)
        require(not path.is_absolute() and '\\' not in name and ':' not in name
                and '..' not in path.parts and path.as_posix() == name
                and len(path.parts) > 1 and path.parts[0] == 'third_party',
                'Invalid vendored source path: ' + name)
        require(name not in recorded, 'Duplicate vendored source: ' + name)
        require(isinstance(digest, str) and re.fullmatch(r'[0-9a-f]{64}', digest),
                'Invalid SHA-256 for ' + name)
        source = root / name
        require(source.is_file() and not source.is_symlink(), 'Missing regular source: ' + name)
        require(sha256(source.read_bytes()) == digest, 'Raw-byte SHA-256 mismatch: ' + name)
        recorded.add(name)
    actual = {p.relative_to(root).as_posix() for p in (root / 'third_party').rglob('*')
              if p.is_file() and p != root / 'third_party/SOURCES.json'}
    require(recorded == actual, 'Vendored manifest coverage mismatch; unrecorded: '
            + str(sorted(actual - recorded)) + '; missing: ' + str(sorted(recorded - actual)))
    for name in ('third_party/json/LICENSE.MIT', 'third_party/mpv/LICENSE.ISC'):
        require(name in recorded, 'Missing third-party license record: ' + name)
    print(f'Vendored sources: {len(recorded)} raw-byte SHA-256 checks passed')
    return recorded


def package_inputs(root, recorded, require_license=False):
    # Intentionally independent of package.py: additions require an explicit review here too.
    files = {
        'scripts/splay_core.dll': root / 'build/splay_core.dll',
        'scripts/splay.lua': root / 'scripts/splay.lua',
        'scripts/splay_overlay.lua': root / 'scripts/splay_overlay.lua',
        'scripts/splay_playlist.lua': root / 'scripts/splay_playlist.lua',
        'script-opts/splay.conf.example': root / 'script-opts/splay.conf.example',
        'INSTALL.txt': root / 'packaging/INSTALL.txt',
        'docs/install.md': root / 'docs/install.md',
        'docs/validation.md': root / 'docs/validation.md',
        'docs/validation-v2.md': root / 'docs/validation-v2.md',
        'docs/validation-v3.md': root / 'docs/validation-v3.md',
        'docs/validation-v4.md': root / 'docs/validation-v4.md',
        'docs/upstream-compatibility.md': root / 'docs/upstream-compatibility.md',
        'licenses/SOURCES.json': root / 'third_party/SOURCES.json',
        'THIRD_PARTY_NOTICES.md': root / 'THIRD_PARTY_NOTICES.md',
    }
    for name in recorded:
        path = PurePosixPath(name)
        if 'LICENSE' in path.name:
            files['licenses/' + path.relative_to('third_party').as_posix()] = root / name
    license_path = root / 'LICENSE'
    require(not require_license or license_path.is_file(), 'Project LICENSE is required')
    if license_path.is_file():
        files['LICENSE'] = license_path
    for name, source in files.items():
        require(source.is_file() and not source.is_symlink(), 'Missing regular package input: ' + name)
        require(source.stat().st_size > 0, 'Empty package input: ' + name)
    return files


def verify_x64_dll(data):
    require(len(data) >= 64 and data[:2] == b'MZ', 'Plugin must have a PE DOS header')
    offset = struct.unpack_from('<I', data, 0x3c)[0]
    require(offset + 26 <= len(data) and data[offset:offset + 4] == b'PE\0\0',
            'Plugin must have a valid PE header')
    machine = struct.unpack_from('<H', data, offset + 4)[0]
    characteristics = struct.unpack_from('<H', data, offset + 22)[0]
    magic = struct.unpack_from('<H', data, offset + 24)[0]
    require(machine == 0x8664 and magic == 0x20b and characteristics & 0x2000,
            'Plugin must be a Windows x64 DLL')


def verify_package(root, archive_path, recorded, require_license=False):
    files = package_inputs(root, recorded, require_license)
    require(archive_path.is_file(), 'Missing release archive: ' + str(archive_path))
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        require(len(names) == len(set(name.casefold() for name in names)),
                'Duplicate or case-conflicting ZIP entries')
        require(set(names) == set(files), 'Package allowlist mismatch; unexpected: '
                + str(sorted(set(names) - set(files))) + '; missing: '
                + str(sorted(set(files) - set(names))))
        for entry in entries:
            require(not entry.is_dir() and (entry.external_attr >> 16) & 0o170000 != 0o120000,
                    'ZIP entry must be a regular file: ' + entry.filename)
            require(archive.read(entry) == files[entry.filename].read_bytes(),
                    'Packaged bytes differ from source: ' + entry.filename)
        verify_x64_dll(archive.read('scripts/splay_core.dll'))
    checksum_path = archive_path.with_name(archive_path.name + '.sha256')
    expected = sha256(archive_path.read_bytes()) + '  ' + archive_path.name + '\n'
    require(checksum_path.read_text(encoding='ascii') == expected,
            'Release checksum must match archive bytes and filename')
    print(f'Package: {len(files)} allowlisted files match source, including all four runtime files')
    print('Windows x64 DLL, licenses, notices and ZIP SHA-256 passed; no extra runtime/private files')
    if not (root / 'LICENSE').is_file():
        print('Project LICENSE is not present; third-party licenses were checked')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources-only', action='store_true', help='Check vendored bytes before building')
    parser.add_argument('--archive', type=Path, help='ZIP to verify; defaults to the only dist/*.zip')
    parser.add_argument('--require-license', action='store_true', help='Require a project LICENSE too')
    args = parser.parse_args()
    try:
        recorded = verify_sources(ROOT)
        if not args.sources_only:
            archive_path = args.archive
            if archive_path is None:
                archives = sorted((ROOT / 'dist').glob('*.zip'))
                require(len(archives) == 1, 'Expected exactly one dist/*.zip; use --archive to select one')
                archive_path = archives[0]
            verify_package(ROOT, archive_path, recorded, args.require_license)
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print('Verification failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
