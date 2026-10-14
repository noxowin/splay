from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
output = root / '.local/ui-review'
output.mkdir(parents=True, exist_ok=True)
mpv = root / '.local/mpv/runtime/mpv.exe'
for mode in ('native', 'uosc'):
    capture = output / (mode + '.png')
    capture.unlink(missing_ok=True)
    args = [str(mpv), '--no-config', '--ao=null', '--pause=yes', '--force-window=yes',
            '--autofit=1100x700', '--screenshot-format=png',
            '--osd-fonts-dir=' + str(root / '.local/uosc/fonts'),
            '--script=' + str(root / 'scripts/splay.lua'),
            '--script=' + str(root / 'tests/ui/splay_core.lua'),
            '--script=' + str(root / 'tests/ui/review.lua'),
            '--script-opts=review-mode=' + mode + ',review-output=' + str(capture),
            str(root / '.local/test-media.mp4')]
    if mode == 'uosc':
        args += ['--script=' + str(root / '.local/uosc/scripts/uosc')]
    # subprocess.run kills and waits for the direct process on timeout.
    result = subprocess.run(args, cwd=root, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=15)
    text = result.stdout.decode('utf-8', errors='replace')
    (output / (mode + '.log')).write_text(text, encoding='utf-8')
    assert result.returncode == 0, text
    assert 'Lua error' not in text and 'stack traceback' not in text, text
    assert 'UI_READY_COMMAND' in text, text
    assert capture.is_file() and capture.stat().st_size > 10000, text
    print(mode + ': real media window captured; ready command boolean asserted')
print('Offline UI review: 2/2 passed; mocked core, no protocol compatibility claim')
