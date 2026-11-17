"""Production password forms, current-user DPAPI and real Syncplay servers.

Everything lives under a fresh .local directory. Only processes assigned to
this harness's Windows job are closed. Requires access to the Windows user's
DPAPI keys; run outside the restricted-account sandbox.
"""
import argparse
import hashlib
import json
import msvcrt
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import uuid

from interop import Job, ROOT, background_window, wait_for


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
    args = parser.parse_args()
    output = ROOT / '.local/credential-ui-path' / ('run-' + uuid.uuid4().hex[:8])
    config = output / 'isolated-mpv'
    (config / 'scripts').mkdir(parents=True)
    (config / 'script-opts').mkdir()
    env = dict(os.environ, APPDATA=str(output / 'appdata'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    Path(env['APPDATA']).mkdir()
    job, processes, logs, players = Job(), [], [], []
    password_a, password_b = ('UI_DPAPI_A_' + uuid.uuid4().hex, 'UI_DPAPI_B_' + uuid.uuid4().hex)
    room = 'credential-' + uuid.uuid4().hex[:8]
    credential_file, history_file = config / 'splay-credentials.json', config / 'splay-history.json'

    def launch(name, command):
        log = (output / (name + '.log')).open('wb')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW,
                                   startupinfo=background_window())
        job.assign(process)
        processes.append(process)
        return process

    def free_port():
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            return listener.getsockname()[1]

    def listening(port):
        with socket.socket() as client:
            return client.connect_ex(('127.0.0.1', port)) == 0

    class Player:
        def __init__(self, name):
            self.serial, self.pipe = 0, None
            for source in ('build/splay_core.dll', 'scripts/splay.lua', 'scripts/splay_overlay.lua', 'scripts/splay_playlist.lua'):
                path = ROOT / source
                if path.is_file():
                    shutil.copy2(path, config / 'scripts' / path.name)
            # Observe the real overlay's already-public non-secret state handoff.
            # The production overlay still handles every message normally.
            overlay_source=(ROOT/'scripts/splay_overlay.lua').read_text(encoding='utf-8')
            (config/'scripts/splay_overlay.lua').write_text('''local register=mp.register_script_message
mp.register_script_message=function(name,fn)
    if name=='splay-state' then register(name,function(json)
        mp.set_property_native('user-data/splay-test-state',require('mp.utils').parse_json(json));fn(json)
    end) else register(name,fn) end
end
'''+overlay_source,encoding='utf-8')
            (config/'scripts/splay.lua').write_text('''local input=require 'mp.input'
local original_osd=mp.osd_message
mp.osd_message=function(text,...)
    mp.set_property_native('user-data/splay-test-notice',text)
    return original_osd(text,...)
end
for _,kind in ipairs({'get','select'}) do
    local original=input[kind]
    input[kind]=function(request)
        local status={kind=kind,prompt=request.prompt,items=request.items,submitted=false,closed=false}
        mp.set_property_native('user-data/splay-test-input',status)
        local submit,closed=request.submit,request.closed
        request.submit=function(value)
            status.submitted=true
            mp.set_property_native('user-data/splay-test-input',status)
            if submit then submit(value) end
        end
        request.closed=function(...)
            status.closed=true;mp.set_property_native('user-data/splay-test-input',status)
            if closed then closed(...) end
        end
        -- Only the length of the line, so a test can tell every key arrived
        -- without the probe ever holding what was typed.
        local edited=request.edited
        request.edited=function(text,...)
            status.length=#tostring(text or '')
            mp.set_property_native('user-data/splay-test-input',status)
            if edited then return edited(text,...) end
        end
        return original(request)
    end
end
'''+(ROOT/'scripts/splay.lua').read_text(encoding='utf-8'),encoding='utf-8')
            self.pipe_name = r'\\.\pipe\splay_credentials_' + uuid.uuid4().hex
            command = [args.mpv, '--load-scripts=no', '--config-dir=' + str(config), '--vo=null', '--ao=null',
                       '--pause=yes', '--idle=yes', '--input-ipc-server=' + self.pipe_name, '--msg-level=all=warn',
                       '--script=' + str(config / 'scripts/splay_core.dll'),
                       '--script=' + str(config / 'scripts/splay.lua'),
                       '--script=' + str(config / 'scripts/splay_overlay.lua'), ROOT / '.local/test-media.mp4']
            self.process = launch(name, command)
            players.append(self)
            def opened():
                try:
                    self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                    return True
                except OSError:
                    return False
            wait_for(name + ' isolated real mpv IPC ready', opened)
            wait_for(name + ' production splay initialized', lambda: self.state())
            assert self.state()['enabled'] is False and self.state()['connection'] == 'disconnected'

        def cmd(self, *command):
            self.serial += 1
            self.pipe.write((json.dumps(dict(command=command, request_id=self.serial)) + '\n').encode())
            while True:
                line = self.pipe.readline()
                assert line, 'isolated player IPC closed'
                reply = json.loads(line)
                if reply.get('request_id') == self.serial:
                    assert reply['error'] == 'success', reply
                    return reply.get('data')

        def get(self, property_name):
            try:
                return self.cmd('get_property', property_name)
            except AssertionError:
                return None

        def state(self):
            return self.get('user-data/splay') or {}

        def full_state(self):
            return self.get('user-data/splay-test-state') or {}

        def action(self, name):
            self.cmd('script-message-to', 'splay', 'splay-action', name)

        def console_ready(self):
            # The form is requested before the console has taken over the
            # keys; a key sent in between goes to the player and is lost.
            wait_for('console is open for keys', lambda: self.get('user-data/mpv/console/open') is True)
            time.sleep(.4)

        def submit(self, value):
            # Use real console keys. New mpv assigns input-event/N handlers;
            # depending on a private callback name would skip the real form.
            self.console_ready()
            if isinstance(value, int):
                assert value == 1
            else:
                self.cmd('keypress', 'Ctrl+a')
                self.cmd('keypress', 'Ctrl+k')
                for character in str(value):
                    self.cmd('keypress', 'SPACE' if character == ' ' else character)
            self.cmd('keypress', 'ENTER')
            time.sleep(.06)

        def select_row(self, needle):
            # Drive the real mp.input selector; do not invoke its callback directly.
            status = wait_for('real selector contains ' + needle, lambda:
                (lambda state: state if state.get('kind') == 'select' and not state.get('closed')
                 and any(needle in item for item in state.get('items', [])) else None)
                (self.get('user-data/splay-test-input') or {}))
            index = next(i for i, item in enumerate(status['items']) if needle in item)
            self.console_ready()
            for _ in status['items']:
                self.cmd('keypress', 'UP')
            for _ in range(index):
                self.cmd('keypress', 'DOWN')
            self.cmd('keypress', 'ENTER')
            time.sleep(.1)

        def field(self, name, value):
            if name=='password':
                self.password('password',value)
                return
            self.action(name)
            wait_for('production ' + name + ' form opens', lambda: self.get('user-data/mpv/console/open') is True)
            history = json.loads(history_file.read_text(encoding='utf-8')) if history_file.exists() else {}
            if name != 'password' and history.get('values', {}).get(name):
                self.submit(1)  # The actual history selector's manual-entry row.
                wait_for('manual non-secret field input is ready',lambda:(self.get('user-data/splay-test-input') or {}).get('kind')=='get')
            self.submit(str(value))
            status=self.get('user-data/splay-test-input') or {}
            assert status.get('submitted') or status.get('items'),status
            self.cmd('keypress', 'ESC')

        def password_prompt(self):
            status=self.get('user-data/splay-test-input') or {}
            return status if status.get('kind')=='get' and not status.get('closed') and \
                '输入时可见' in (status.get('prompt') or '') else None

        def type_keys(self, text):
            """Type text into the open console line, one key at a time.

            A key sent over IPC is now and then lost before it reaches the
            console. The probe reports the line's length, so a short line is
            cleared and typed again instead of being submitted wrong.
            """
            for attempt in range(3):
                for character in text:
                    self.cmd('keypress', character)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if (self.get('user-data/splay-test-input') or {}).get('length') == len(text):
                        return
                    time.sleep(.05)
                print('typed again: the console line has the wrong length (attempt %d)' % (attempt + 1), flush=True)
                self.cmd('keypress', 'Ctrl+a')
                self.cmd('keypress', 'Ctrl+k')
                time.sleep(.3)
            raise AssertionError('keys typed into the console kept getting lost')

        def fill_password(self,secret=None,key='ENTER'):
            # Real console keys into the production password prompt.
            wait_for('production password prompt opens in the mpv console',self.password_prompt)
            self.console_ready()
            if secret:
                self.type_keys(secret)
            if key=='CLOSE':
                # Opening the panel replaces the prompt: closed, never submitted.
                self.action('connection')
                wait_for('the panel replaces the password prompt',lambda:
                         (self.get('user-data/splay-test-input') or {}).get('kind')=='select')
                self.console_ready()
                self.cmd('keypress','ESC')
            else:
                self.cmd('keypress', key)
            wait_for('production password prompt closes',lambda:not self.password_prompt())

        def password(self,action,secret=None,key='ENTER'):
            self.action(action)
            self.fill_password(secret,key)

        def close(self):
            if self.process.poll() is None:
                try:
                    self.pipe.write(b'{"command":["quit"]}\n')
                except (OSError, AttributeError):
                    pass
                self.process.wait(timeout=8)
            if self.pipe:
                self.pipe.close()
                self.pipe = None

    class StoreLock:
        """Hold the exact byte-range lock used by the native credential store."""
        def __enter__(self):
            self.file = open(str(credential_file) + '.lock', 'a+b')
            self.file.seek(0)
            msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            return self

        def __exit__(self, *_):
            self.file.seek(0)
            msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
            self.file.close()

    def connected(player, description):
        try:
            wait_for(description, lambda: player.state().get('connection') == 'connected')
        except AssertionError:
            state=player.full_state()
            raise AssertionError(description+'; connection='+str(state.get('connection'))+'; error='+str(state.get('error')))
        assert player.get('path') == str(ROOT / '.local/test-media.mp4')

    def disconnected(player):
        player.action('disconnect')
        wait_for('production UI disconnect completes', lambda: player.state().get('connection') == 'disconnected')

    def entries():
        return json.loads(credential_file.read_text(encoding='utf-8'))['entries'] if credential_file.exists() else []

    try:
        port_a, port_b = free_port(), free_port()
        while port_b == port_a:
            port_b = free_port()
        for name, port, secret in (('server-A', port_a, password_a), ('server-B', port_b, password_b)):
            launch(name, [ROOT / '.venv/Scripts/python.exe', ROOT / '.local/upstream/syncplay-1.7.6/syncplayServer.py',
                          '--port', port, '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--password', secret])
            wait_for('unmodified password-protected ' + name + ' listens', lambda port=port: listening(port))
        (config / 'script-opts/splay.conf').write_text(
            'host=127.0.0.1\nport=' + str(port_a) + '\nusername=credential-ui\nroom=' + room +
            '\ntls=off\nremember_password=yes\nlanguage=zh-CN\n', encoding='utf-8')
        first = Player('first-process')
        first.action('toggle-enabled')
        with StoreLock():
            first.field('password', password_a)
            first.action('connect')
            time.sleep(.15)
        connected(first, 'fast connect waits for encrypted password save and authenticates server A')
        assert len(entries()) == 1 and entries()[0]['port'] == port_a
        encrypted_before = credential_file.read_bytes()
        saved_room = room + '-saved-only'
        first.field('room', saved_room)
        first.action('history-management')
        first.select_row('保存当前连接组合')
        try:
            wait_for('explicit save stores the new connection combination', lambda:
                     any(profile['room'] == saved_room for profile in
                         json.loads(history_file.read_text(encoding='utf-8'))['profiles']))
        except AssertionError as exc:
            raise AssertionError(str(exc) + '; notice=' + str(first.get('user-data/splay-test-notice'))) from exc
        assert first.state()['room'] == room, 'saving a form must not change the live room'
        first.action('profiles')
        first.select_row(saved_room)
        first.select_row('删除此组合')
        first.select_row('确认删除:')
        wait_for('real selector confirmation deletes only the chosen combination', lambda:
                 all(profile['room'] != saved_room for profile in
                     json.loads(history_file.read_text(encoding='utf-8'))['profiles']))
        assert any(profile['room'] == room for profile in
                   json.loads(history_file.read_text(encoding='utf-8'))['profiles'])
        assert credential_file.read_bytes() == encrypted_before, 'combination deletion must retain endpoint password'
        assert first.state()['room'] == room and first.get('path') == str(ROOT / '.local/test-media.mp4')
        first.action('create-form')
        wait_for('create ordinary room prompts explicitly for a new name', lambda:
                 (first.get('user-data/splay-test-input') or {}).get('kind') == 'get' and
                 '新普通房间' in (first.get('user-data/splay-test-input') or {}).get('prompt', ''))
        first.submit(room + '-created')
        assert first.state()['room'] == room, 'entering a new name alone must not connect or change rooms'
        first.cmd('keypress', 'ESC')
        first.action('connect')
        wait_for('create-and-enter uses the real saved server credential', lambda:
                 first.state().get('connection') == 'connected' and first.state().get('room') == room + '-created')
        assert not first.full_state().get('controlled'), 'ordinary create must not create an operator-controlled room'
        first.action('join-form')
        first.cmd('keypress', 'ESC')
        first.field('room', room)
        first.action('connect')
        wait_for('join form returns to the requested room', lambda:
                 first.state().get('connection') == 'connected' and first.state().get('room') == room)
        assert first.get('path') == str(ROOT / '.local/test-media.mp4')
        first.close()
        second = Player('restarted-process')
        second.action('toggle-enabled')
        second.action('connect')
        connected(second, 'fresh process connects without retyping password through init/status readiness')
        disconnected(second)
        prior=credential_file.read_bytes()
        second.password('password','SYNTHETIC_CANCEL_NOT_SAVED',key='ESC')
        time.sleep(.25)
        assert credential_file.read_bytes()==prior,'Escape must leave encrypted credential unchanged'
        second.password('password','SYNTHETIC_CLOSE_NOT_SAVED',key='CLOSE')
        time.sleep(.25)
        assert credential_file.read_bytes()==prior,'Closing the prompt unsubmitted must leave encrypted credential unchanged'
        second.action('connect')
        connected(second,'Escape and closing the prompt retain the previously saved password')
        disconnected(second)
        second.field('room', room + '-other')
        second.action('connect')
        connected(second, 'different room reuses the same server credential')
        assert second.state()['room'] == room + '-other', (second.state()['room'],room+'-other')
        disconnected(second)
        second.field('port', port_b)
        second.action('connect')
        wait_for('same host on a different port cannot reuse server A password', lambda: second.state().get('connection') == 'error')
        assert len(entries()) == 1
        with StoreLock():
            second.field('password', password_b)
            second.action('connect')
            time.sleep(.15)
        connected(second, 'production form separately saves and authenticates server B')
        assert {entry['port'] for entry in entries()} == {port_a, port_b}
        disconnected(second)
        with StoreLock():
            second.field('port', port_a)
            second.action('connect')
            time.sleep(.15)
        connected(second, 'fast connect waits for endpoint status and uses server A rather than port B')
        disconnected(second)
        second.cmd('script-message-to', 'splay', 'splay-credential', json.dumps(
            dict(schema=1, request_id=2, host='127.0.0.1', port=port_a, saved=False)))
        second.action('connect')
        connected(second, 'stale same-endpoint status reply cannot overwrite saved credentials')
        disconnected(second)
        second.action('toggle-remember-password')
        second.action('connect')
        wait_for('turning password memory off does not use an existing saved password', lambda: second.state().get('connection') == 'error')
        assert len(entries()) == 2
        second.action('toggle-remember-password')
        second.action('connect')
        connected(second, 'turning memory back on retains and reuses encrypted credentials')
        disconnected(second)
        with StoreLock():
            second.action('clear-password')
            second.action('connect')
            time.sleep(.15)
        wait_for('delete-before-connect waits and cannot reuse an in-memory or saved password',
                 lambda: second.state().get('connection') == 'error')
        assert [entry['port'] for entry in entries()] == [port_b]
        second.close()
        third = Player('restart-after-delete')
        third.action('toggle-enabled')
        third.action('connect')
        wait_for('fresh process after deletion cannot automatically authenticate server A',
                 lambda: third.state().get('connection') == 'error')
        third.action('toggle-remember-password')
        third.field('password',password_a)
        third.action('connect')
        connected(third,'temporary typed password authenticates without restoring deleted credential')
        assert [entry['port'] for entry in entries()]==[port_b]
        disconnected(third);third.action('connect')
        connected(third,'temporary typed password is reused only from the current endpoint hash')
        third.password('authenticate',None,key='ESC')
        assert third.state()['connection']=='connected'
        controlled='prompt-'+uuid.uuid4().hex[:6]
        third.action('create-room')
        wait_for('controlled-room name uses non-secret console form',lambda:third.get('user-data/mpv/console/open') is True)
        third.submit(controlled)
        third.fill_password('bad-synthetic-operator')
        time.sleep(.2)
        assert third.state()['connection']=='connected','Validation failure must preserve the connection'
        third.action('create-room')
        wait_for('controlled-room form can reopen after validation error',lambda:third.get('user-data/mpv/console/open') is True)
        third.submit(controlled)
        operator_password='SY-314-159'
        third.fill_password(operator_password)
        wait_for('typed operator password creates a controlled room',lambda:controlled in third.state().get('room','') and third.state().get('room','').startswith('+'))
        wait_for('controlled room creation authenticates the operator',lambda:third.full_state().get('is_controller') is True)
        third.password('authenticate',operator_password)
        wait_for('typed operator authentication succeeds',lambda:third.full_state().get('is_controller') is True)
        third.password('authenticate','ZZ-000-000')
        wait_for('wrong typed operator password reports server authentication error',lambda:third.full_state().get('error')=='Operator authentication failed')
        third.password('authenticate',operator_password)
        wait_for('operator prompt reopens after authentication failure',lambda:not third.full_state().get('error'))
        third.action('password')
        wait_for('password prompt remains open for mpv shutdown test',third.password_prompt)
        third.close()
        assert third.process.returncode==0,'mpv must quit cleanly with the password prompt open'
        excluded = [secret.encode('utf-8') for secret in (password_a, password_b)]
        excluded += [hashlib.md5(secret.encode()).hexdigest().encode() for secret in (password_a, password_b)]
        excluded += [value.encode() for value in (operator_password,'SYNTHETIC_CANCEL_NOT_SAVED','SYNTHETIC_CLOSE_NOT_SAVED','bad-synthetic-operator')]
        for path in (history_file, credential_file):
            raw = path.read_bytes()
            assert all(value not in raw for value in excluded), 'secret or protocol password hash persisted in ' + path.name
        for path in config.rglob('*'):
            if path.is_file() and 'scripts' not in path.parts:
                assert all(value not in path.read_bytes() for value in excluded), 'secret persisted in isolated configuration data'
        for path in output.glob('*.log'):
            assert all(value not in path.read_bytes() for value in excluded), 'secret leaked into child process logs'
        history = json.loads(history_file.read_text(encoding='utf-8'))
        assert all(set(profile) == {'host', 'port', 'username', 'room', 'tls'} for profile in history['profiles'])
        result = dict(result='passed', server='unmodified Syncplay 1.7.6', dpapi='current Windows user',
                      production_ui='splay.lua; passwords and other fields typed into the real mpv console (mp.input)', fresh_processes=3,
                      checks=['fast save/connect', 'explicit combination save and real selector deletion preserves password/live room/media',
                              'ordinary create and join forms require explicit connect and preserve media',
                              'restart', 'room reuse', 'port isolation',
                              'fast endpoint status/connect', 'stale same-endpoint reply', 'opt out', 'delete/restart',
                              'prompt Escape/unsubmitted close preserves saved password','temporary password endpoint hash reuse',
                              'controlled-room creation/operator authentication and failure/reopen','shutdown with password prompt open',
                              'encrypted file only; no plaintext or MD5 in history/configuration'],
                      credential_ports=[entry['port'] for entry in entries()], artifacts=str(output))
        (output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: production credential forms, real restart, port/room isolation, fast status/save, stale replies, opt-out, deletion and no plaintext/MD5 persistence; ' + str(output), flush=True)
    finally:
        job.close()
        for process in processes:
            process.wait(timeout=8)
        for player in players:
            if player.pipe:
                player.pipe.close()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
