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

def command(path, action, **fields):
    payload=dict(action=action, **fields)
    payload.setdefault('request_id', {'operation':action,'sequence':[1,2]})
    result=subprocess.run([str(exe),str(path)], input=json.dumps(payload),text=True,encoding='utf-8',
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=8)
    assert result.returncode==0,result.stderr
    response=json.loads(result.stdout)
    assert response['request_id']==payload['request_id'],response
    return response

artifact_root=Path(__file__).resolve().parents[2]/'.local'
artifact_root.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='splay-history-',dir=artifact_root) as folder:
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

    managed=Path(folder)/'managed.json'
    original=profile(200)
    call(managed,original)
    # Existing processes must re-read other players' saves and management writes.
    stale=subprocess.Popen([str(exe),str(managed),'--stream'],stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
    assert json.loads(stale.stdout.readline())['profiles']==[original]
    try:
        second=profile(201);call(managed,second)
        renamed=command(managed,'history-rename',settings=dict(original,password='RENAME_SECRET'),name='我的服务器')
        assert renamed['profiles'][0]==dict(original,name='我的服务器')
        stale.stdin.write(json.dumps(dict(action='history-save',settings=original,remember_profile=True))+'\n')
        stale.stdin.flush()
        reread=json.loads(stale.stdout.readline())
        assert reread['profiles']==[dict(original,name='我的服务器'),second]
        deleted=command(managed,'history-delete',settings=original)
        assert deleted['profiles']==[second] and deleted['last']=={}
        stale.stdin.write(json.dumps(dict(action='history-save',settings=profile(202),remember_profile=True))+'\n')
        stale.stdin.flush()
        assert json.loads(stale.stdout.readline())['profiles']==[second,profile(202)]
    finally:
        stale.stdin.close();stale.wait(timeout=8)
        assert stale.returncode==0,stale.stderr.read()
    assert command(managed,'history-delete',settings=original)['profiles']==[second,profile(202)]
    # Clearing suggestions survives process restart even while profiles/last retain values.
    for field in original:
        cleared=command(managed,'history-clear-values',field=field)
        assert cleared['values'][field]==[]
        assert call(managed)['values'][field]==[]
    assert len(call(managed)['profiles'])==2
    legacy_path=Path(folder)/'legacy.json'
    legacy_path.write_text(json.dumps(dict(schema=1,last=original,profiles=[original])),encoding='utf-8')
    assert call(legacy_path)['values']['host']==[original['host']]
    command(legacy_path,'history-clear-values',field='host')
    assert call(legacy_path)['values']['host']==[]
    partial=dict(schema=1,last=original,profiles=[original],values={'host':[]})
    legacy_path.write_text(json.dumps(partial),encoding='utf-8')
    assert all(not values for values in call(legacy_path)['values'].values())

    # Parallel names, deletions and unrelated saves must merge against current disk state.
    concurrent_path=Path(folder)/'management-races.json'
    for i in range(20):call(concurrent_path,profile(300+i))
    def manage(index):
        if index<10:return command(concurrent_path,'history-rename',settings=profile(300+index),name='Saved '+str(index))
        if index<20:return command(concurrent_path,'history-delete',settings=profile(300+index))
        return call(concurrent_path,profile(300+index))
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        responses=list(pool.map(manage,range(30)))
    assert all('error' not in result for result in responses),responses
    final=call(concurrent_path)
    assert len(final['profiles'])==20
    for i in range(10):
        assert dict(profile(300+i),name='Saved '+str(i)) in final['profiles']
        call(concurrent_path,profile(300+i))
    assert all(item['host'] not in {profile(300+i)['host'] for i in range(10,20)} for item in final['profiles'])
    assert all('name' in item for item in call(concurrent_path)['profiles'] if item['host'] in {profile(300+i)['host'] for i in range(10)})
    # A rename racing the deletion of its own identity may fail, but cannot resurrect it.
    same_target=profile(400);call(concurrent_path,same_target)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rename=pool.submit(command,concurrent_path,'history-rename',settings=same_target,name='Racing name')
        delete=pool.submit(command,concurrent_path,'history-delete',settings=same_target)
        rename_result,delete_result=rename.result(),delete.result()
    assert 'error' not in delete_result
    assert not any(item['host']==same_target['host'] for item in call(concurrent_path)['profiles'])
    if 'error' in rename_result:assert 'does not exist' in rename_result['error']

    # Legacy extra fields are stripped even from a named profile, on load and later writes.
    legacy_path.write_text(json.dumps(dict(schema=1,last={},profiles=[dict(second,name='Named',password='LEGACY_SECRET',mediaURL='private')],values={})),encoding='utf-8')
    assert call(legacy_path)['profiles']==[dict(second,name='Named')]
    sanitized=command(legacy_path,'history-rename',settings=second,name='Renamed')
    assert sanitized['profiles']==[dict(second,name='Renamed')]
    assert 'LEGACY_SECRET' not in legacy_path.read_text(encoding='utf-8')

    previous=managed.read_bytes()
    for action,fields in (
        ('history-rename',dict(settings=second,name='')),
        ('history-rename',dict(settings=second,name='bad\nname')),
        ('history-rename',dict(settings=second,name=4)),
        ('history-rename',dict(settings=second,name='x'*1025)),
        ('history-rename',dict(settings=original,name='absent')),
        ('history-rename',dict(settings=dict(second,room=''),name='bad')),
        ('history-delete',dict(settings={'host':'partial'})),
        ('history-delete',dict(settings=dict(second,port=True))),
        ('history-clear-values',dict(field='password')),
        ('history-clear-values',dict(field=['host'])),
        ('history-clear-values',{}),('history-unknown',{})):
        assert 'error' in command(managed,action,**fields),(action,fields)
        assert managed.read_bytes()==previous
    assert 'RENAME_SECRET' not in previous.decode('utf-8') and 'password' not in previous.decode('utf-8')
    # The history component never touches the separately stored endpoint secrets.
    secret_file=Path(folder)/'endpoint-credentials.json'
    secret_file.write_bytes(b'credential-store-sentinel')
    cleared=command(managed,'history-clear',password='CLEAR_SECRET')
    assert cleared['last']=={} and cleared['profiles']==[] and all(not x for x in cleared['values'].values())
    assert call(managed)['profiles']==[] and call(managed)['last']=={}
    assert secret_file.read_bytes()==b'credential-store-sentinel'
    assert 'CLEAR_SECRET' not in managed.read_text(encoding='utf-8')
    for damage in (b'{broken',json.dumps(dict(schema=1,last={},profiles=[dict(second,name=12)])).encode()):
        managed.write_bytes(damage)
        for action,fields in (('history-clear',{}),('history-clear-values',dict(field='host')),
                              ('history-delete',dict(settings=second)),('history-rename',dict(settings=second,name='Good'))):
            assert 'error' in command(managed,action,**fields)
            assert managed.read_bytes()==damage

    # UI preferences are independent from connection history and merge under
    # the same process lock, including when an older player is still open.
    prefs_path=Path(folder)/'preferences.json'
    assert call(prefs_path)['preferences']=={}
    assert command(prefs_path,'history-preferences',preferences={'chat_mode':'danmaku'})['preferences']=={'chat_mode':'danmaku'}
    prefs={'chat_mode':'danmaku','pause_on_join':False,'pause_on_leave':True}
    assert command(prefs_path,'history-preferences',preferences={'pause_on_join':False,'pause_on_leave':True})['preferences']==prefs
    assert call(prefs_path)['preferences']==prefs, 'preferences survive a fresh process'
    stale=subprocess.Popen([str(exe),str(prefs_path),'--stream'],stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8')
    assert json.loads(stale.stdout.readline())['preferences']==prefs
    try:
        command(prefs_path,'history-preferences',preferences={'chat_mode':'room'})
        stale.stdin.write(json.dumps(dict(action='history-save',settings=profile(500),remember_profile=True))+'\n')
        stale.stdin.flush()
        latest=json.loads(stale.stdout.readline())
        prefs['chat_mode']='room'
        assert latest['preferences']==prefs and latest['profiles']==[profile(500)]
    finally:
        stale.stdin.close();stale.wait(timeout=8)
        assert stale.returncode==0,stale.stderr.read()
    # Three disjoint preference writes racing profile saves cannot drop keys.
    parallel_path=Path(folder)/'preferences-races.json'
    operations=[lambda:command(parallel_path,'history-preferences',preferences={'chat_mode':'danmaku'}),
                lambda:command(parallel_path,'history-preferences',preferences={'pause_on_join':False}),
                lambda:command(parallel_path,'history-preferences',preferences={'pause_on_leave':False})]
    operations.extend(lambda i=i:call(parallel_path,profile(600+i)) for i in range(12))
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        outcomes=list(pool.map(lambda operation:operation(),operations))
    assert all('error' not in result for result in outcomes),outcomes
    expected={'chat_mode':'danmaku','pause_on_join':False,'pause_on_leave':False}
    final=call(parallel_path)
    assert final['preferences']==expected and len(final['profiles'])==12
    command(parallel_path,'history-clear-values',field='room')
    assert call(parallel_path)['preferences']==expected
    command(parallel_path,'history-clear')
    final=call(parallel_path)
    assert final['preferences']==expected and final['last']=={} and final['profiles']==[]
    assert all(not value for value in final['values'].values())
    previous=parallel_path.read_bytes()
    for invalid in (None,[],True,{'chat_mode':'unknown'},{'chat_mode':True},
                    {'pause_on_join':1},{'pause_on_leave':'false'},
                    {'password':'SYNTHETIC_PREF_SECRET'},{'time_offset':12}):
        assert 'error' in command(parallel_path,'history-preferences',preferences=invalid),invalid
        assert parallel_path.read_bytes()==previous
    assert command(parallel_path,'history-preferences',preferences={})['preferences']==expected
    # Loading damaged preferences fails explicitly and never overwrites bytes.
    for invalid in ([],{'pause_on_join':None},{'chat_mode':'unknown'},{'unknown':True}):
        stored=dict(schema=1,last={},profiles=[],values={},preferences=invalid)
        damaged=json.dumps(stored).encode('utf-8');parallel_path.write_bytes(damaged)
        assert 'error' in call(parallel_path)
        assert 'error' in command(parallel_path,'history-preferences',preferences={'chat_mode':'room'})
        assert parallel_path.read_bytes()==damaged
print('History: blank-room draft restart, strict completed profiles and stored values, legacy rooms, mixed draft/profile merges, Unicode paths, 30 concurrent profile merges, dedup, secrets whitelist, validation, corruption and failed write preservation passed')
print('History management: named identities, stale-process re-read, parallel rename/delete/save merge, authoritative cleared suggestions, legacy migration, request IDs, strict input and secret isolation passed')
print('History preferences: fresh-process persistence, stale-player save preservation, concurrent independent merges, clear preservation and invalid data protection passed')
