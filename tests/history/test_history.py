"""Actual Windows processes: Unicode paths, restart, concurrent merge, corruption and failed writes."""
from pathlib import Path
import concurrent.futures
import json
import os
import stat
import subprocess
import sys
import tempfile

exe = Path(sys.argv[1]).resolve()
def call(path, settings=None, remember=True):
    data = '' if settings is None else json.dumps({'action':'history-save','settings':settings,'remember_profile':remember})
    result = subprocess.run([str(exe), str(path)], input=data, text=True, encoding='utf-8',
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)
def profile(index=0):
    return dict(host='server'+str(index)+'.example',port=8999+index,username='用户'+str(index),room='房间'+str(index),tls='prefer')

with tempfile.TemporaryDirectory(prefix='splay-history-') as folder:
    path = Path(folder)/'中文目录'/'splay-history.json'
    path.parent.mkdir()
    assert call(path)['profiles'] == [] and not path.exists()
    # A draft remembers filled fields across fresh processes without inventing a room.
    draft_path=path.parent/'draft-history.json'
    draft=profile(70);draft['room']=''
    draft.update(password='DRAFT_SECRET',mediaURL='https://private.example/draft')
    saved_draft=call(draft_path,draft,False)
    clean_draft={key:draft[key] for key in profile()}
    assert 'error' not in saved_draft and saved_draft['last']==clean_draft
    assert saved_draft['schema']==1 and saved_draft['profiles']==[]
    restored_draft=call(draft_path)
    assert restored_draft['last']==clean_draft, 'blank-room draft must survive process restart'
    assert restored_draft['values']['room']==[], 'empty room must never become a suggestion'
    for key in ('host','port','username','tls'):
        assert restored_draft['values'][key]==[draft[key]], 'filled draft fields must be remembered'
    draft_raw=draft_path.read_text(encoding='utf-8')
    assert 'DRAFT_SECRET' not in draft_raw and 'mediaURL' not in draft_raw and 'password' not in draft_raw
    draft_previous=draft_path.read_bytes()
    assert 'error' in call(draft_path,draft,True), 'blank room cannot become a completed profile'
    assert draft_path.read_bytes()==draft_previous, 'rejected completed profile must preserve file bytes'
    assert not list(draft_path.parent.glob('*.tmp-*'))
    # Only room may be empty in a draft; existing type, range and text checks remain strict.
    for key,bad_value in (('host',''),('username',''),('tls',''),('port',0),('port',65536),
                          ('port','8999'),('room',None),('room','bad\nroom'),
                          ('room','x'*1025),('tls','unknown')):
        bad_draft=clean_draft.copy();bad_draft[key]=bad_value
        assert 'error' in call(draft_path,bad_draft,False), (key,bad_value)
        assert draft_path.read_bytes()==draft_previous
    missing_room=clean_draft.copy();del missing_room['room']
    assert 'error' in call(draft_path,missing_room,False) and draft_path.read_bytes()==draft_previous
    # Schema 1 history retains explicit old room values, including Default.
    legacy=profile(71);legacy['room']='Default'
    assert call(draft_path,legacy)['profiles']==[legacy]
    assert call(draft_path,clean_draft,False)['values']['room']==['Default']
    custom=profile(72);custom['room']='my-custom-room'
    assert call(draft_path,custom)['values']['room']==['Default','my-custom-room']
    assert call(draft_path,clean_draft,False)['profiles']==[legacy,custom]
    assert call(draft_path)['last']==clean_draft
    # Blank drafts from competing players must merge their filled fields and completed profiles.
    mixed_path=path.parent/'mixed-history.json'
    def mixed_save(index):
        item=profile(100+index)
        if index%2:item['room']=''
        return call(mixed_path,item,index%2==0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        mixed_results=list(pool.map(mixed_save,range(20)))
    assert all('error' not in result for result in mixed_results),mixed_results
    mixed=call(mixed_path)
    assert len(mixed['profiles'])==10 and len(mixed['values']['room'])==10
    assert '' not in mixed['values']['room']
    assert {item['host'] for item in mixed['profiles']}=={profile(100+i)['host'] for i in range(0,20,2)}
    assert set(mixed['values']['host'])=={profile(100+i)['host'] for i in range(20)}
    # Loading allows empty last.room, but never empty room profiles or stored suggestions.
    valid_draft=json.loads(draft_path.read_text(encoding='utf-8'))
    for invalid in (dict(valid_draft,profiles=[clean_draft]),
                    dict(valid_draft,values=dict(valid_draft['values'],room=[''])),
                    dict(valid_draft,last=dict(clean_draft,host=''))):
        damaged=json.dumps(invalid).encode('utf-8')
        draft_path.write_bytes(damaged)
        assert 'error' in call(draft_path)
        assert 'error' in call(draft_path,profile(73))
        assert draft_path.read_bytes()==damaged
    first=profile()
    first.update(password='MUST_NOT_PERSIST',mediaURL='https://private.example/secret')
    assert call(path,first)['last']==profile()
    raw=path.read_text(encoding='utf-8')
    assert 'MUST_NOT_PERSIST' not in raw and 'mediaURL' not in raw and 'password' not in raw
    assert call(path)['last']==profile(), 'separate process must restore last values'
    assert call(path,profile())['profiles']==[profile()], 'complete profile deduplication'
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        results=list(pool.map(lambda i: call(path,profile(i)),range(1,31)))
    assert all('error' not in result for result in results),results
    loaded=call(path)
    assert len(loaded['profiles'])==31 and len(loaded['values']['room'])==31, loaded
    assert {p['host'] for p in loaded['profiles']}=={profile(i)['host'] for i in range(31)}
    assert not list(path.parent.glob('*.tmp-*'))
    # Same identity with a changed TLS policy is a distinct complete profile.
    other=profile();other['tls']='require'
    assert len(call(path,other)['profiles'])==32
    last_only=profile(40)
    assert len(call(path,last_only,False)['profiles'])==32
    assert call(path)['last']==last_only
    previous=path.read_bytes()
    bad=profile();bad['port']=0
    assert 'error' in call(path,bad) and path.read_bytes()==previous
    path.chmod(stat.S_IREAD)
    try:
        assert 'error' in call(path,profile(50)), 'read-only existing file must report replace failure'
        assert path.read_bytes()==previous, 'failed atomic replacement must preserve previous file'
    finally:
        path.chmod(stat.S_IREAD|stat.S_IWRITE)
    for damaged in (b'{broken',b'{"schema":1,"last":{},"profiles":[{"host":"partial"}]}',previous+b'trailing'):
        path.write_bytes(damaged)
        assert 'error' in call(path), 'damaged load must be explicit'
        assert 'error' in call(path,profile(60)), 'damaged history must not be overwritten'
        assert path.read_bytes()==damaged
    assert 'error' in call(Path(folder)/'missing'/'history.json',profile())
print('History: blank-room draft restart, strict completed profiles and stored values, legacy rooms, mixed draft/profile merges, Unicode paths, 30 concurrent profile merges, dedup, secrets whitelist, validation, corruption and failed write preservation passed')
