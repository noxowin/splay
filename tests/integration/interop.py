"""Real Windows mpv + unmodified Syncplay 1.7.6 interoperability harness.

Run with the repository venv Python. Artifacts stay in .local/integration.
Both players run without user configuration, audio, or a visible video output.
The observer scripts only collect properties and execute this harness's local
commands; they do not implement or simulate Syncplay behavior.
"""
import argparse
import ctypes
import hashlib
from ctypes import wintypes
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]

class Job:
    def __init__(self):
        class BASIC(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', wintypes.DWORD), ('min_ws', ctypes.c_size_t),
                        ('max_ws', ctypes.c_size_t), ('active', wintypes.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', wintypes.DWORD),
                        ('scheduling', wintypes.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ('read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes')]
        class EXTENDED(ctypes.Structure):
            _fields_ = [('basic', BASIC), ('io', IO), ('process_memory', ctypes.c_size_t),
                        ('job_memory', ctypes.c_size_t), ('peak_process', ctypes.c_size_t),
                        ('peak_job', ctypes.c_size_t)]
        self.api = ctypes.WinDLL('kernel32', use_last_error=True)
        self.api.CreateJobObjectW.restype = wintypes.HANDLE
        self.api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        info = EXTENDED()
        info.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.handle or not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            raise ctypes.WinError(ctypes.get_last_error())
    def assign(self, process):
        if not self.api.AssignProcessToJobObject(self.handle, wintypes.HANDLE(int(process._handle))):
            process.terminate()
            raise ctypes.WinError(ctypes.get_last_error())
    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None

def wait_for(description, predicate, seconds=15):
    until = time.monotonic() + seconds
    last = None
    while time.monotonic() < until:
        try:
            last = predicate()
            if last:
                print('PASS:', description, flush=True)
                return last
        except (FileNotFoundError, json.JSONDecodeError, PermissionError):
            pass
        time.sleep(.1)
    raise AssertionError(f'Timed out: {description}; last={last!r}')

OBSERVER = r'''
local utils = require 'mp.utils'
local destination = DESTINATION
local controls = CONTROLS
local state = {}
local events = {}
local sequence = -1
mp.register_script_message('splay-state', function(s)
    state = utils.parse_json(s) or {}
end)
mp.register_script_message('splay-event', function(s)
    -- Keep raw JSON so mpv's NUL-terminated node strings cannot truncate text
    -- while serializing our observation snapshot.
    events[#events + 1] = s
    if #events > 200 then table.remove(events, 1) end
end)
mp.add_periodic_timer(0.1, function()
    local f = io.open(controls, 'r')
    if f then
        local request = utils.parse_json(f:read('*a')); f:close()
        if request and request.sequence ~= sequence then
            sequence = request.sequence
            mp.command_native(request.command)
        end
    end
    local result = {position=mp.get_property_native('time-pos'),
        paused=mp.get_property_native('pause'), path=mp.get_property('path'),
        duration=mp.get_property_native('duration'), state=state, event_json=events}
    local out = io.open(destination .. '.tmp', 'w')
    if out then
        out:write(utils.format_json(result)); out:close()
        os.remove(destination); os.rename(destination .. '.tmp', destination)
    end
end)
'''

class Player:
    def __init__(self, directory, name):
        self.snapshot = directory / (name + '.json')
        self.controls = directory / (name + '-commands.json')
        self.script = directory / ('splay.lua' if name == 'plugin' else 'official-observer.lua')
        self.sequence = 0
        self.script.write_text(OBSERVER.replace('DESTINATION', json.dumps(str(self.snapshot).replace('\\', '/')))
                               .replace('CONTROLS', json.dumps(str(self.controls).replace('\\', '/'))), encoding='utf-8')
    def read(self):
        # Lua's Windows replace has a brief remove/rename gap. Assertions also
        # read snapshots directly, so tolerate that gap here rather than only
        # in wait_for(). Never substitute a stale cached snapshot.
        for attempt in range(25):
            try:
                result = json.loads(self.snapshot.read_text(encoding='utf-8'))
                result['events'] = [json.loads(value) for value in result.pop('event_json', [])]
                return result
            except (FileNotFoundError, json.JSONDecodeError, PermissionError):
                if attempt == 24:
                    raise
                time.sleep(.01)
    def command(self, *command):
        self.sequence += 1
        temp = self.controls.with_suffix('.tmp')
        temp.write_text(json.dumps({'sequence': self.sequence, 'command': list(command)}), encoding='utf-8')
        os.replace(temp, self.controls)
    def splay(self, action, **values):
        self.command('script-message-to', 'splay_core', 'splay-command', json.dumps(dict(action=action, **values)))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
    parser.add_argument('--python', type=Path, default=ROOT / '.venv/Scripts/python.exe')
    parser.add_argument('--upstream', type=Path, default=ROOT / '.local/upstream/syncplay-1.7.6')
    parser.add_argument('--plugin', type=Path, default=ROOT / 'build/splay_core.dll')
    parser.add_argument('--media', default=str(ROOT / '.local/test-media.mp4'))
    parser.add_argument('--http', action='store_true', help='Serve local fixture as two distinct authenticated loopback URLs')
    args = parser.parse_args()
    directory = ROOT / '.local/integration' / (time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    directory.mkdir(parents=True)
    env = os.environ.copy()
    env['APPDATA'] = str(directory / 'appdata')
    env['PYTHONUTF8'] = '1'
    env['PYTHONIOENCODING'] = 'utf-8'
    env['PYTHONUNBUFFERED'] = '1'
    Path(env['APPDATA']).mkdir()
    job = Job()
    processes, logs = [], []
    def launch(name, command, stdin=False):
        log = (directory / (name + '.log')).open('w', encoding='utf-8')
        logs.append(log)
        process = subprocess.Popen([str(v) for v in command], cwd=args.upstream,
                                   env=env, stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        processes.append(process)
        return process
    def stdin_command(process, command):
        process.stdin.write(command + '\n')
        process.stdin.flush()
    def state():
        return plugin.read()['state']
    def chat_seen(username, text):
        return any(e.get('type') == 'chat' and e.get('username') == username and e.get('text') == text
                   for e in plugin.read().get('events', []))
    def official_log():
        return (directory / 'official.log').read_text(encoding='utf-8', errors='replace')
    def server_file(room_name):
        with socket.create_connection(('127.0.0.1', port), timeout=5) as probe:
            with probe.makefile('rwb', buffering=0) as stream:
                stream.write(json.dumps({'Hello': {'username': 'file-probe-' + uuid.uuid4().hex[:6], 'password': hashlib.md5(b'fixture-server-password').hexdigest(), 'room': {'name': 'probe'}, 'version': '1.2.255', 'realversion': '1.7.6'}}).encode() + b'\r\n')
                while 'Hello' not in json.loads(stream.readline()):
                    pass
                stream.write(b'{"List":null}\r\n')
                while True:
                    listing = json.loads(stream.readline()).get('List')
                    if listing is not None:
                        return listing[room_name]['plugin'].get('file')
    def together(paused=None, position=None):
        a, b = official.read(), plugin.read()
        if paused is not None and (a.get('paused') is not paused or b.get('paused') is not paused):
            return False
        if a.get('position') is None or b.get('position') is None:
            return False
        return abs(a['position'] - b['position']) < 2 and (position is None or abs(a['position'] - position) < 3)
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        server = launch('server', [args.python, args.upstream / 'syncplayServer.py', '--port', port,
                          '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'local-integration-salt', '--password', 'fixture-server-password'])
        def listening():
            with socket.socket() as client:
                return client.connect_ex(('127.0.0.1', port)) == 0
        wait_for('unmodified official server listens locally', listening)
        official = Player(directory, 'official')
        plugin = Player(directory, 'plugin')
        official_media = plugin_media = args.media
        if args.http:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                http_port = listener.getsockname()[1]
            launch('http', [args.python, Path(__file__).with_name('http_fixture.py'), '--port', http_port,
                            '--media', args.media])
            official_media = f'http://127.0.0.1:{http_port}/fixture.mp4?test_token=official-fixture-only'
            plugin_media = f'http://127.0.0.1:{http_port}/fixture.mp4?test_token=plugin-fixture-only'
            time.sleep(.5)
        room = 'integration-' + uuid.uuid4().hex[:8]
        cli = launch('official', [args.python, args.upstream / 'syncplayClient.py', '--no-gui', '--no-store',
                                  '--host', f'127.0.0.1:{port}', '--password', 'fixture-server-password', '--name', 'official', '--room', room,
                                  '--player-path', args.mpv, official_media, '--', '--vo=null', '--ao=null',
                                  '--pause=yes', '--no-config', '--scripts-append=' + str(official.script),
                                  '--log-file=' + str(directory / 'official-mpv.log')], stdin=True)
        wait_for('official mpv observer loads', lambda: official.read())
        wait_for('official client owns a loaded real mpv', lambda: official.read().get('duration', 0) > 100)
        time.sleep(3)
        # The official client may unpause asynchronously after opening an HTTP
        # playlist. Establish the test's baseline after startup has completed.
        official.command('set', 'pause', 'yes')
        wait_for('official initial playback is paused', lambda: official.read().get('paused') is True)
        time.sleep(2)
        stdin_command(cli, 's35')
        wait_for('official client seeks before plugin joins', lambda: abs(official.read().get('position', 0) - 35) < 2)
        launch('plugin', [args.mpv, '--no-config', '--vo=null', '--ao=null', '--pause=yes',
                          '--idle=yes', '--script=' + str(args.plugin), '--script=' + str(plugin.script), plugin_media])
        wait_for('plugin real mpv retains caller media', lambda: plugin.read().get('duration', 0) > 100)
        plugin.splay('connect', host='localhost', port=port, username='plugin', room=room, password='wrong-fixture-password', tls='prefer')
        wait_for('wrong server password is rejected', lambda: state().get('connection') == 'error')
        plugin.splay('connect', host='localhost', port=port, username='plugin', room=room, password='fixture-server-password', tls='prefer')
        wait_for('plugin completes Hello and discovers official member',
                 lambda: state().get('connection') == 'connected' and any(m['username'] == 'official' for m in state().get('members', [])))
        wait_for('late join aligns preloaded media position', lambda: together(True, 35))
        assert official.read()['path'] == official_media and plugin.read()['path'] == plugin_media, 'Player media arguments changed'
        print('PASS: both players retain distinct caller media arguments', flush=True)
        # Independent wire-level List confirms what the server actually stores.
        # This observer joins its own room and sends no State/playback changes.
        with socket.create_connection(('127.0.0.1', port), timeout=5) as probe:
            stream = probe.makefile('rwb', buffering=0)
            stream.write(json.dumps({'Hello': {'username': 'privacy-probe', 'password': hashlib.md5(b'fixture-server-password').hexdigest(), 'room': {'name': 'probe-' + uuid.uuid4().hex[:6]}, 'version': '1.2.255', 'realversion': '1.7.6'}}).encode() + b'\r\n')
            while 'Hello' not in json.loads(stream.readline()):
                pass
            stream.write(b'{"List":null}\r\n')
            listing = None
            while listing is None:
                listing = json.loads(stream.readline()).get('List')
            metadata = listing[room]['plugin']['file']
            assert metadata['name'] == '**Hidden filename**' and 'test_token' not in json.dumps(metadata), metadata
            (directory / 'server-plugin-metadata.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
            stream.close()
        print('PASS: server List stores hidden plugin metadata with no media URL/token', flush=True)
        assert state()['chat_supported'] is True and state()['chat_max_length'] == 150
        message = '官方中文聊天 😀 {\\pos(1,1)} "quotes" ; set pause no'
        stdin_command(cli, 'ch ' + message)
        wait_for('official Chinese/special-character chat arrives as an attributed text event',
                 lambda: chat_seen('official', message))
        message = '插件双向聊天 😀 {\\an9} "quotes" ; run cmd /c echo inert'
        plugin.splay('chat', text=message)
        wait_for('plugin Chinese/special-character chat reaches unmodified official client',
                 lambda: '<plugin> ' + message in official_log())
        wait_for('plugin receives its authoritative server chat echo', lambda: chat_seen('plugin', message))
        message = '中😀' * 80
        plugin.splay('chat', text=message)
        wait_for('UTF-8 outgoing chat truncates at 150 codepoints without splitting characters',
                 lambda: chat_seen('plugin', message[:150]) and '<plugin> ' + message[:150] in official_log())
        # Protocol text remains inert even when it contains controls and command-like text.
        message = 'literal\nscript-message-to splay_core disconnect\x00{\\an9}'
        plugin.splay('chat', text=message)
        wait_for('control characters and malicious-looking input round trip strictly as text',
                 lambda: chat_seen('plugin', message))
        assert state()['connection'] == 'connected' and together(True, 35)
        plugin.splay('ready', ready=True)
        wait_for('plugin readiness round trip', lambda: state().get('ready') is True)
        stdin_command(cli, 't')
        wait_for('official readiness appears in plugin members', lambda: any(m['username'] == 'official' and m.get('ready') is True for m in state().get('members', [])))
        stdin_command(cli, 'p')
        wait_for('official play reaches plugin', lambda: together(False))
        wait_for('playback event attributes official pause change to setBy',
                 lambda: any(e.get('type') == 'playback' and e.get('username') == 'official' and e.get('paused') is False
                             for e in plugin.read().get('events', [])))
        time.sleep(2)
        plugin.command('set', 'pause', 'yes')
        wait_for('plugin pause reaches official', lambda: together(True))
        for index, delay in enumerate((.05, .15, .25, .1, .35, .05)):
            paused = bool(index % 2)
            plugin.command('set', 'pause', 'yes' if paused else 'no')
            wait_for(f'rapid plugin pause change {index + 1} reaches official', lambda paused=paused: together(paused))
            time.sleep(delay)
        stdin_command(cli, 's60')
        wait_for('official seek reaches plugin', lambda: together(True, 60))
        time.sleep(2)
        plugin.command('seek', 90, 'absolute+exact')
        wait_for('plugin seek reaches official', lambda: together(True, 90))
        second_room = room + '-second'
        plugin.splay('room', room=second_room)
        wait_for('plugin switches room', lambda: state().get('room') == second_room)
        # The real official client is still in the original room during isolation.
        isolated = 'isolated-' + uuid.uuid4().hex
        stdin_command(cli, 'ch ' + isolated)
        time.sleep(2)
        assert not chat_seen('official', isolated), 'Chat leaked between rooms'
        isolated_out = 'isolated-out-' + uuid.uuid4().hex
        plugin.splay('chat', text=isolated_out)
        wait_for('chat echo remains available in independent second room', lambda: chat_seen('plugin', isolated_out))
        time.sleep(1)
        assert '<plugin> ' + isolated_out not in official_log(), 'Outgoing chat leaked between rooms'
        print('PASS: official and plugin chat is isolated in both directions across rooms', flush=True)
        stdin_command(cli, 'r ' + second_room)
        wait_for('official follows into second room', lambda: any(m['username'] == 'official' and m['room'] == second_room for m in state().get('members', [])))
        plugin.splay('create-room', room='ctl-' + uuid.uuid4().hex[:8], password='AA-123-456')
        controlled = wait_for('plugin creates controlled room and authenticates', lambda: state().get('controlled') and state().get('is_controller') and state().get('room'))
        stdin_command(cli, 'r ' + controlled)
        wait_for('official joins controlled room as ordinary member', lambda: any(m['username'] == 'official' and m['room'] == controlled for m in state().get('members', [])))
        time.sleep(2)
        before = plugin.read()
        previous_events = len(before.get('events', []))
        stdin_command(cli, 's20')
        stdin_command(cli, 'p')
        time.sleep(3)
        after = plugin.read()
        assert after['paused'] == before['paused'] and abs(after['position'] - before['position']) < 1, 'Ordinary controlled member changed operator playback'
        assert len(after.get('events', [])) == previous_events, 'Rejected ordinary member generated a playback activity event'
        print('PASS: ordinary controlled member seek/pause cannot alter operator playback', flush=True)
        stdin_command(cli, 'a AA-123-456')
        wait_for('official operator authentication appears in plugin', lambda: any(m['username'] == 'official' and m.get('is_controller') for m in state().get('members', [])))
        stdin_command(cli, 's25')
        wait_for('authenticated official operator seek changes room', lambda: together(True, 25))
        plugin.splay('disconnect')
        wait_for('plugin actively disconnects', lambda: state().get('connection') == 'disconnected')
        before = plugin.read()['position']
        stdin_command(cli, 's20')
        time.sleep(2)
        assert abs(plugin.read()['position'] - before) < 2, 'Disconnected plugin followed remote seek'
        print('PASS: disconnect keeps independent local playback', flush=True)
        plugin.splay('connect', host='localhost', port=port, username='plugin', room=controlled, password='fixture-server-password', tls='prefer')
        wait_for('manual reconnect completes', lambda: state().get('connection') == 'connected')
        wait_for('reconnected plugin is ordinary controlled member', lambda: state().get('controlled') and not state().get('is_controller'))
        plugin.splay('authenticate', password='wrong-operator-password')
        wait_for('wrong operator password rejected', lambda: bool(state().get('error')) and not state().get('is_controller'))
        plugin.splay('authenticate', password='AA-123-456')
        wait_for('correct operator password accepted and error cleared', lambda: state().get('is_controller') and not state().get('error'))
        plugin.command('set', 'pause', 'yes')
        time.sleep(2)
        event_count = len(plugin.read().get('events', []))
        print('Waiting 30 seconds to verify paused heartbeat and idle connection...', flush=True)
        time.sleep(30)
        assert state()['connection'] == 'connected' and plugin.read()['paused'] is True, state()
        assert len(plugin.read().get('events', [])) == event_count, 'Heartbeat generated repeated playback events'
        print('PASS: paused 30-second heartbeat retains connection', flush=True)
        assert plugin.read()['path'] == plugin_media and official.read()['path'] == official_media
        plugin.command('stop')
        wait_for('stopped media clears actual server List metadata', lambda: not server_file(controlled))
        plugin.command('loadfile', plugin_media)
        wait_for('reloaded fixture restores hidden actual server List metadata', lambda: (server_file(controlled) or {}).get('name') == '**Hidden filename**')
        server.terminate()
        server.wait(timeout=5)
        wait_for('server loss stops plugin synchronization', lambda: state().get('connection') in ('error', 'disconnected'))
        before = plugin.read()['position']
        plugin.command('seek', 110, 'absolute+exact')
        wait_for('local seeking works after external server loss', lambda: abs(plugin.read()['position'] - 110) < 2)
        before = plugin.read()['position']
        plugin.command('set', 'pause', 'no')
        wait_for('local playback advances after external server loss', lambda: plugin.read().get('paused') is False and plugin.read().get('position', 0) > before + 2)
        # An unmodified --disable-chat server advertises the feature as disabled.
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            disabled_port = listener.getsockname()[1]
        launch('server-chat-disabled', [args.python, args.upstream / 'syncplayServer.py', '--port', disabled_port,
               '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--disable-chat', '--salt', 'local-disabled-salt'])
        def disabled_listening():
            with socket.socket() as client:
                return client.connect_ex(('127.0.0.1', disabled_port)) == 0
        wait_for('unmodified chat-disabled server listens locally', disabled_listening)
        plugin.splay('connect', host='localhost', port=disabled_port, username='plugin', room='disabled-fixture', tls='off')
        wait_for('server disabled chat is exposed by negotiated status',
                 lambda: state().get('connection') == 'connected' and state().get('chat_supported') is False)
        plugin.splay('chat', text='must be rejected locally')
        wait_for('disabled chat returns explicit error and keeps synchronization connected',
                 lambda: state().get('connection') == 'connected' and 'Chat is disabled' in state().get('error', ''))
        result = {'result': 'passed', 'mpv': str(args.mpv), 'upstream': str(args.upstream), 'artifacts': str(directory)}
        (directory / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    except Exception as exc:
        (directory / 'result.json').write_text(json.dumps({'result': 'failed', 'error': str(exc)}, indent=2), encoding='utf-8')
        raise
    finally:
        # Kill-on-close applies to official client's mpv descendants as well.
        job.close()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for log in logs:
            log.close()
        print('Artifacts:', directory, flush=True)

if __name__ == '__main__':
    main()
