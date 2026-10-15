from pathlib import Path
import subprocess
import argparse

root = Path(__file__).resolve().parents[2]
output = root / '.local/ui-review-v4'
output.mkdir(parents=True, exist_ok=True)
parser=argparse.ArgumentParser()
parser.add_argument('--mpv',type=Path,default=root/'.local/mpv/runtime/mpv.exe')
parser.add_argument('--uosc',type=Path,default=root/'.local/uosc/scripts/uosc')
parser.add_argument('--fonts',type=Path,default=root/'.local/uosc/fonts')
opts=parser.parse_args()
mpv=opts.mpv
fixture = output/'review-driver.lua'
fixture.write_text("""
local options=require 'mp.options'
local utils=require 'mp.utils'
local opt={mode='native',page='home',output=''}
options.read_options(opt,'review')
mp.add_timeout(.4,function()
    assert(mp.get_property_native('user-data/splay').enabled==false)
    if opt.page~='disabled' then mp.commandv('script-message-to','splay','splay-action','toggle-enabled') end
end)
mp.add_timeout(.8,function()
    mp.commandv('script-message-to','splay','splay-credential',utils.format_json({schema=1,host='syncplay.pl',port=8999,saved=true}))
    mp.commandv('script-message-to','splay','splay-state',utils.format_json({schema=1,
        connection='connected',encrypted=true,username='本机用户',room='中文房间',ready=false,
        playlist_supported=true,playlist={files={'第一集.mp4','第二集.mp4'},index=0,user='另一位成员'},
        warning='Synchronization requires playback speed 1.0; synchronization is suspended',
        members={{username='另一位成员',room='中文房间',ready=true}}}))
    mp.commandv('script-message-to','splay','splay-event',utils.format_json({schema=1,id=1,type='connection',connection='connected'}))
    mp.commandv('script-message-to','splay','splay-event',utils.format_json({schema=1,id=2,type='ready',username='另一位成员',ready=true}))
    mp.commandv('script-message-to','splay','splay-open',opt.mode)
end)
mp.add_timeout(1.1,function()
    if opt.page~='home' and opt.page~='disabled' then
        mp.commandv('script-message-to','splay','splay-action',opt.page)
    end
end)
mp.add_timeout(1.8,function()
    mp.commandv('screenshot-to-file',opt.output,'window')
    print('REVIEW_CAPTURE '..opt.mode..' '..opt.page)
end)
mp.add_timeout(2.05,function()
    if opt.page~='disabled' then mp.commandv('script-message-to','splay','splay-action','ready') end
end)
mp.add_timeout(2.5,function() mp.commandv('quit') end)
""",encoding='utf-8')
pages=('disabled','home','connection','endpoint','settings','password-settings','room-actions','members','message-history')
for mode, page in ((mode,page) for mode in ('native', 'uosc') for page in pages):
    config=output/(mode+'-config')
    config.mkdir(exist_ok=True)
    capture = output / (mode + '-' + page + '.png')
    capture.unlink(missing_ok=True)
    args = [str(mpv), '--no-config', '--config-dir='+str(config), '--ao=null', '--pause=yes', '--force-window=yes',
            '--autofit=1100x700', '--screenshot-format=png',
            '--osd-fonts-dir=' + str(opts.fonts),
            '--script=' + str(root / 'scripts/splay.lua'),
            '--script=' + str(root / 'tests/ui/splay_core.lua'),
            '--script=' + str(fixture),
            '--script-opts=splay-room=中文房间,splay-username=本机用户,review-mode=' + mode + ',review-page=' + page + ',review-output=' + str(capture),
            str(root / '.local/test-media.mp4')]
    if mode == 'uosc':
        args += ['--script=' + str(opts.uosc)]
    # subprocess.run kills and waits for the direct process on timeout.
    result = subprocess.run(args, cwd=root, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=15)
    text = result.stdout.decode('utf-8', errors='replace')
    (output / (mode + '-' + page + '.log')).write_text(text, encoding='utf-8')
    assert result.returncode == 0, text
    assert 'Lua error' not in text and 'stack traceback' not in text, text
    if page != 'disabled': assert 'UI_READY_COMMAND' in text, text
    assert capture.is_file() and capture.stat().st_size > 10000, text
    print(mode + '/' + page + ': real media window captured; default off and enabled ready command asserted')
print('Offline UI review: 18/18 passed; mocked core, no protocol compatibility claim')
