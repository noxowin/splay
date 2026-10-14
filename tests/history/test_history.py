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
print('History: Unicode path, separate process restore, 30 concurrent merges, dedup, secrets whitelist, last-only saves, corruption and failed write preservation passed')
