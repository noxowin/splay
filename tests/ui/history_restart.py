"""Auto-load the real DLL and Lua twice from an isolated mpv config."""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--mpv',type=Path,default=root/'.local/mpv/runtime/mpv.exe')
opts=parser.parse_args()
config=root/'.local/ui-history-restart'
(config/'scripts').mkdir(parents=True,exist_ok=True)
(config/'script-opts').mkdir(exist_ok=True)
for source in (root/'build/splay_core.dll',root/'scripts/splay.lua',root/'scripts/splay_overlay.lua'):
    shutil.copy2(source,config/'scripts'/source.name)
(config/'script-opts/splay.conf').write_text('host=localhost\nusername=old-example\n',encoding='utf8')
fixture=dict(host='restored.example',port=9009,username='重启昵称',room='重启房间',tls='require')
other=dict(host='other.example',port=8999,username='other',room='other-room',tls='off')
path=config/'splay-history.json'
path.write_text(json.dumps(dict(schema=1,last=fixture,profiles=[other,fixture],values={})),encoding='utf8')
blank=dict(fixture,room='')
for number,stage in enumerate(('profile','draft','restart'),1):
    result=subprocess.run([str(opts.mpv),'--config-dir='+str(config),'--idle=yes','--vo=null','--ao=null',
        '--msg-level=all=debug','--script='+str(root/'tests/ui/history_restart_driver.lua'),
        '--script-opts=history_restart-stage='+stage],
        cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=12)
    text=result.stdout.decode('utf8',errors='replace')
    (config/f'run-{number}.log').write_text(text,encoding='utf8')
    assert result.returncode==0 and 'HISTORY_RESTART_SAVED '+stage in text,text
    assert 'HISTORY_RESTART_DISABLED true' in text,text
    assert 'Lua error' not in text and 'stack traceback' not in text,text
    data=json.loads(path.read_text(encoding='utf8'))
    assert data['last']==(fixture if stage=='profile' else blank),data
    assert data['profiles']==[other,fixture],data
    assert data['values']['room']==[other['room'],fixture['room']],data
    for key in ('host','port','username','tls'):
        assert fixture[key] in data['values'][key],data
    assert 'splay-history' in text and 'splay_core' in text,text
    # Debug command records prove neither restore nor blocked blank actions reach connect.
    assert not re.search(r'"action"\s*:\s*"(?:connect|room)"',text.replace('\\"','"')),text
    assert '"connection":"connecting"' not in text.replace('\\"','"'),text
print('UI history restart: real DLL/Lua auto-loaded in three isolated mpv processes; saved fields restored over old config, clearing room persisted through restart, completed profiles and room suggestions preserved, every player starts disabled, blank connect blocked, no reconnect')
