"""Actual mpv Lua loading and native/uosc entrypoint smoke (not visual QA)."""
from pathlib import Path
import subprocess
import argparse

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--mpv',type=Path,default=root/'.local/mpv/runtime/mpv.com')
parser.add_argument('--uosc',type=Path,default=root/'.local/uosc/scripts/uosc')
opts=parser.parse_args()
mpv=opts.mpv
if not mpv.is_file(): raise SystemExit('Place the verified mpv build in .local/mpv/runtime first')
for uosc in (False, True):
    config=root/'.local'/('ui-smoke-uosc' if uosc else 'ui-smoke-native')
    config.mkdir(parents=True,exist_ok=True)
    args=[str(mpv),'--no-config','--config-dir='+str(config),'--idle=yes','--force-window=yes','--ao=null',
          '--script='+str(root/'scripts/splay.lua'),'--script='+str(root/'tests/ui/driver.lua')]
    if uosc: args+=['--script='+str(opts.uosc)]
    result=subprocess.run(args,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    text=result.stdout.decode('utf-8',errors='replace')
    print(('WITH UOSC' if uosc else 'NATIVE ONLY')+'\n'+text)
    assert result.returncode==0 and 'UI_SMOKE_COMPLETED' in text
    assert 'Lua error' not in text and 'stack traceback' not in text
    if uosc: assert 'UOSC_MENU splay' in text, 'uosc did not open splay menu'
    else: assert 'UOSC_MENU none' in text
print('UI smoke: 2/2 passed (entrypoint/load checks; no pixel or keyboard assertions)')
result=subprocess.run([str(mpv),'--no-config','--idle=yes','--vo=null','--ao=null',
    '--script='+str(root/'tests/ui/forms.lua'),'--script-opts=forms-source='+str(root/'scripts/splay.lua')],
    cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
text=result.stdout.decode('utf-8',errors='replace')
assert result.returncode==0 and 'UI_FORMS_PASSED' in text,text
assert 'Lua error' not in text and 'stack traceback' not in text,text
print(text)
