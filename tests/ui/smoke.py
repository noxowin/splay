"""Actual mpv Lua loading and native/uosc entrypoint smoke (not visual QA)."""
from pathlib import Path
import subprocess
import argparse
import json
import sys

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--mpv',type=Path,default=root/'.local/mpv/runtime/mpv.exe')
parser.add_argument('--uosc',type=Path,default=root/'.local/uosc/scripts/uosc')
parser.add_argument('--output',type=Path,default=root/'.local/ui-smoke')
opts=parser.parse_args()
sys.path.insert(0,str(root/'tests/integration'))
from interop import Job, background_window
def run_player(command):
    job=Job()
    process=subprocess.Popen(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                             creationflags=subprocess.CREATE_NO_WINDOW,startupinfo=background_window(minimized=True))
    job.assign(process)
    try:
        try: output,_=process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            job.close()
            output,_=process.communicate(timeout=5)
            raise AssertionError('Fixture timed out:\n'+output.decode('utf-8',errors='replace'))
        return subprocess.CompletedProcess(command,process.returncode,output)
    finally: job.close()
mpv=opts.mpv
if not mpv.is_file(): raise SystemExit('Place the verified mpv build in .local/mpv/runtime first')
opts.output.mkdir(parents=True,exist_ok=True)
for uosc in (False, True):
    mode='uosc' if uosc else 'native'
    config=opts.output/mode
    config.mkdir(parents=True,exist_ok=True)
    args=[str(mpv),'--no-config','--load-scripts=no','--config-dir='+str(config),'--idle=yes','--force-window=yes','--geometry=1100x800','--ao=null','--pause=yes',
          '--osd-fonts-dir='+str(root/'.local/uosc/fonts'),
          '--script='+str(root/'scripts/splay.lua'),'--script='+str(root/'tests/ui/driver.lua'),
          '--script-opts=splay-language=zh-CN,driver-mode='+mode+',driver-output='+str(config.resolve()),str(root/'.local/test-media.mp4')]
    if uosc: args+=['--script='+str(opts.uosc)]
    result=run_player(args)
    text=result.stdout.decode('utf-8',errors='replace')
    (opts.output/(mode+'.log')).write_text(text,encoding='utf-8')
    print(('WITH UOSC' if uosc else 'NATIVE ONLY')+'\n'+text)
    assert result.returncode==0 and 'UI_SMOKE_COMPLETED' in text
    assert 'Lua error' not in text and 'stack traceback' not in text
    if uosc: assert 'UOSC_MENU splay' in text, 'uosc did not open splay menu'
    else: assert 'UOSC_MENU none' in text
print('UI smoke: 2/2 passed (default off, explicit enable and native/uosc entrypoints)')
forms_config=opts.output/'forms'
forms_config.mkdir(exist_ok=True)
result=run_player([str(mpv),'--no-config','--load-scripts=no','--config-dir='+str(forms_config),'--idle=yes','--vo=null','--ao=null',
    '--script='+str(root/'tests/ui/forms.lua'),'--script-opts=forms-source='+str(root/'scripts/splay.lua')])
text=result.stdout.decode('utf-8',errors='replace')
(opts.output/'forms.log').write_text(text,encoding='utf-8')
assert result.returncode==0 and 'UI_FORMS_PASSED' in text,text
assert 'Lua error' not in text and 'stack traceback' not in text,text
print(text)
playlist_config=opts.output/'playlist-forms'
playlist_config.mkdir(exist_ok=True)
result=run_player([str(mpv),'--no-config','--load-scripts=no','--config-dir='+str(playlist_config),'--idle=yes','--vo=null','--ao=null',
    '--script='+str(root/'tests/ui/playlist_forms.lua'),'--script-opts=playlist_forms-source='+str(root/'scripts/splay_playlist.lua')])
text=result.stdout.decode('utf-8',errors='replace')
(opts.output/'playlist-forms.log').write_text(text,encoding='utf-8')
assert result.returncode==0 and 'PLAYLIST_FORMS_PASSED' in text,text
assert 'Lua error' not in text and 'stack traceback' not in text,text
print(text)
(opts.output/'result.json').write_text(json.dumps({'passed':True,'native':True,'uosc':True,'forms':True,'playlist_forms':True,'network_mocked':True},indent=2),encoding='utf-8')
