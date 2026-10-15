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

from interop import Job, ROOT, wait_for


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
                                   stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
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

        def action(self, name):
            self.cmd('script-message-to', 'splay', 'splay-action', name)

        def submit(self, value):
            # Use real console keys. New mpv assigns input-event/N handlers;
            # depending on a private callback name would skip the real form.
            if isinstance(value, int):
                assert value == 1
            else:
                self.cmd('keypress', 'Ctrl+a')
                self.cmd('keypress', 'Ctrl+k')
                for character in str(value):
                    self.cmd('keypress', 'SPACE' if character == ' ' else character)
            self.cmd('keypress', 'ENTER')
            time.sleep(.06)

        def field(self, name, value):
            self.action(name)
            wait_for('production ' + name + ' form opens', lambda: self.get('user-data/mpv/console/open') is True)
            history = json.loads(history_file.read_text(encoding='utf-8')) if history_file.exists() else {}
            if name != 'password' and history.get('values', {}).get(name):
                self.submit(1)  # The actual history selector's manual-entry row.
            self.submit(str(value))
            self.cmd('keypress', 'ESC')

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
        wait_for(description, lambda: player.state().get('connection') == 'connected')
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
            '\ntls=off\nremember_password=yes\n', encoding='utf-8')
        first = Player('first-process')
        first.action('toggle-enabled')
        with StoreLock():
            first.field('password', password_a)
            first.action('connect')
            time.sleep(.15)
        connected(first, 'fast connect waits for encrypted password save and authenticates server A')
        assert len(entries()) == 1 and entries()[0]['port'] == port_a
        first.close()
        second = Player('restarted-process')
        second.action('toggle-enabled')
        second.action('connect')
        connected(second, 'fresh process connects without retyping password through init/status readiness')
        disconnected(second)
        second.field('room', room + '-other')
        second.action('connect')
        connected(second, 'different room reuses the same server credential')
        assert second.state()['room'] == room + '-other'
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
        excluded = [secret.encode('utf-8') for secret in (password_a, password_b)]
        excluded += [hashlib.md5(secret.encode()).hexdigest().encode() for secret in (password_a, password_b)]
        for path in (history_file, credential_file):
            raw = path.read_bytes()
            assert all(value not in raw for value in excluded), 'secret or protocol password hash persisted in ' + path.name
        for path in config.rglob('*'):
            if path.is_file() and 'scripts' not in path.parts:
                assert all(value not in path.read_bytes() for value in excluded), 'secret persisted in isolated configuration data'
        history = json.loads(history_file.read_text(encoding='utf-8'))
        assert all(set(profile) == {'host', 'port', 'username', 'room', 'tls'} for profile in history['profiles'])
        result = dict(result='passed', server='unmodified Syncplay 1.7.6', dpapi='current Windows user',
                      production_ui='splay.lua + real mp.input forms', fresh_processes=3,
                      checks=['fast save/connect', 'restart', 'room reuse', 'port isolation',
                              'fast endpoint status/connect', 'stale same-endpoint reply', 'opt out', 'delete/restart',
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
