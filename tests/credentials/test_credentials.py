"""Windows DPAPI checks in fresh processes; plaintext never leaves the native comparison driver.

Another Windows account is intentionally not impersonated: DPAPI account isolation is
provided by user-scope CryptProtectData, and requires a second real account to validate.
"""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import stat
import subprocess
import sys
import tempfile

exe=Path(sys.argv[1]).resolve()
secret='记住🔐-SERVER_SECRET-123'

def call(path,action=None,host='syncplay.example',port=8999,**extra):
    command=dict(action=action,host=host,port=port,**extra) if action else None
    result=subprocess.run([str(exe),str(path)],input=json.dumps(command) if command else '',
                          text=True,encoding='utf-8',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
    assert result.returncode==0,result.stderr
    # Public command responses and comparison responses must never reveal the secret or its protocol hash.
    assert secret not in result.stdout and hashlib.md5(secret.encode()).hexdigest() not in result.stdout
    return json.loads(result.stdout)

def save(path,host='syncplay.example',port=8999,password=secret):
    return call(path,'credential-save',host,port,password=password)

def compare(path,host='syncplay.example',port=8999,expected=secret):
    return call(path,'test-compare',host,port,expected=expected)

def status(path,host='syncplay.example',port=8999):
    return call(path,'credential-status',host,port)

with tempfile.TemporaryDirectory(prefix='splay-credentials-') as folder:
    path=Path(folder)/'中文目录'/'splay-credentials.json'
    path.parent.mkdir()
    assert call(path)==dict(schema=1,saved=False) and not path.exists()
    assert status(path)==dict(schema=1,host='syncplay.example',port=8999,saved=False)
    assert 'error' in compare(path), 'missing password must fail, without falling back to an empty password'
    assert save(path,host='  SyncPlay.Example\t')==dict(schema=1,host='syncplay.example',port=8999,saved=True)
    assert compare(path)==dict(matches=True), 'separate process must decrypt for the same Windows user'
    assert compare(path,expected='other')==dict(matches=False)
    assert status(path,'other.example')['saved'] is False and 'error' in compare(path,'other.example')
    assert status(path,port=9000)['saved'] is False and 'error' in compare(path,port=9000)
    raw=path.read_text(encoding='utf-8')
    for excluded in (secret,hashlib.md5(secret.encode()).hexdigest(),'password','room','username'):
        assert excluded not in raw
    original=path.read_bytes()
    for extra in (dict(host=''),dict(host='bad host'),dict(host='x'*254),dict(host='bad\x00host'),
                  dict(port=0),dict(port=65536),dict(port='8999'),dict(port=True),dict(port=2**64-1),
                  dict(password=''),dict(password='x'*1025),dict(password='bad\npassword'),dict(password=None)):
        assert 'error' in save(path,**extra),extra
        assert path.read_bytes()==original, 'invalid input must preserve existing ciphertext'
    # Saving a changed password replaces only this endpoint.
    assert save(path,password='replacement')['saved'] is True
    assert compare(path,expected='replacement')['matches']
    assert save(path,port=9000,password='other-port')['saved']
    assert save(path,'other.example',password='other-host')['saved']
    assert compare(path,port=9000,expected='other-port')['matches']
    assert compare(path,'other.example',expected='other-host')['matches']
    # An endpoint copied inside the file cannot use a different endpoint's ciphertext.
    stored=json.loads(path.read_text(encoding='utf-8'))
    stored['entries'][0]['host']='copied.example'
    copied=path.parent/'copied.json';copied.write_text(json.dumps(stored),encoding='utf-8')
    assert status(copied,'copied.example')['saved']
    assert 'cannot be decrypted' in compare(copied,'copied.example')['error']
    stored['entries'][0]['host']='syncplay.example';stored['entries'][0]['port']=9999
    copied.write_text(json.dumps(stored),encoding='utf-8')
    assert 'cannot be decrypted' in compare(copied,port=9999)['error']
    # A syntactically valid, modified encrypted blob fails explicitly and is not overwritten.
    stored['entries'][0]['port']=8999
    blob=stored['entries'][0]['blob'];stored['entries'][0]['blob']=('1' if blob[0]!='1' else '2')+blob[1:]
    copied.write_text(json.dumps(stored),encoding='utf-8');tampered=copied.read_bytes()
    assert 'cannot be decrypted' in compare(copied)['error'] and copied.read_bytes()==tampered
    assert call(path,'credential-delete')['saved'] is False
    assert status(path)['saved'] is False and 'error' in compare(path)
    assert compare(path,port=9000,expected='other-port')['matches']
    assert call(path,'credential-delete')['saved'] is False, 'deleting absent entry is idempotent'
    concurrent_path=path.parent/'concurrent.json'
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        results=list(pool.map(lambda i:save(concurrent_path,f'server{i}.example',8999+i,f'pw-{i}'),range(30)))
    assert all('error' not in result for result in results),results
    assert len(json.loads(concurrent_path.read_text(encoding='utf-8'))['entries'])==30
    for i in range(30):
        assert compare(concurrent_path,f'server{i}.example',8999+i,expected=f'pw-{i}')['matches']
    previous=path.read_bytes()
    path.chmod(stat.S_IREAD)
    try:
        assert 'error' in save(path), 'read-only existing file must report atomic replacement failure'
        assert 'error' in call(path,'credential-delete',port=9000)
        assert path.read_bytes()==previous
    finally:
        path.chmod(stat.S_IREAD|stat.S_IWRITE)
    malformed=json.loads(previous)
    malformed['entries'][0]['password']='PLAINTEXT_MUST_NOT_BE_ACCEPTED'
    too_many=dict(schema=1,entries=[dict(host=f'{i}.example',port=8999,blob='00') for i in range(257)])
    for damaged in (b'{broken',previous+b'trailing',b'{}',json.dumps(malformed).encode(),
                    json.dumps(too_many).encode(),b'x'*(4*1024*1024+1)):
        path.write_bytes(damaged)
        assert 'error' in call(path) and 'error' in save(path) and 'error' in call(path,'credential-delete')
        assert path.read_bytes()==damaged, 'damaged files must be preserved, including unknown secret fields'
    assert 'error' in save(Path(folder)/'missing'/'credentials.json')
    assert not list(path.parent.glob('*.tmp-*'))
print('Credentials: current-user DPAPI separate-process restart, encrypted-only file/payload, endpoint normalization/isolation/entropy, overwrite/delete, 30 concurrent merges, strict limits, tamper detection, corruption and atomic failure preservation passed')
print('Account-isolation limitation: no second Windows account available; no cross-account decryption test claimed')
