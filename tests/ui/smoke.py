"""Actual mpv Lua loading and native/uosc entrypoint smoke (not visual QA)."""
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[2]
mpv=root/'.local/mpv/runtime/mpv.com'
if not mpv.is_file(): raise SystemExit('Place the verified mpv build in .local/mpv/runtime first')
for uosc in (False, True):
    args=[str(mpv),'--no-config','--idle=yes','--force-window=yes','--ao=null',
          '--script='+str(root/'scripts/splay.lua'),'--script='+str(root/'tests/ui/driver.lua')]
    if uosc: args+=['--script='+str(root/'.local/uosc/scripts/uosc')]
    result=subprocess.run(args,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
    text=result.stdout.decode('utf-8',errors='replace')
    print(('WITH UOSC' if uosc else 'NATIVE ONLY')+'\n'+text)
    assert result.returncode==0 and 'UI_SMOKE_COMPLETED' in text
    assert 'Lua error' not in text and 'stack traceback' not in text
    if uosc: assert 'UOSC_MENU splay' in text, 'uosc did not open splay menu'
    else: assert 'UOSC_MENU none' in text
print('UI smoke: 2/2 passed (entrypoint/load checks; no pixel or keyboard assertions)')
