"""Shared-playlist and explicit-unpause checks with unmodified Syncplay 1.7.6.

Run after building the native plugin. Uses the existing real-mpv observer and
process cleanup helpers; artifacts remain under .local/integration.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

from interop import Job, Player as ObserverPlayer, ROOT, wait_for


class Player(ObserverPlayer):
    def command(self, *command):
        # The Lua observer briefly opens this file without Windows delete
        # sharing. Retry the atomic replacement rather than changing its IO.
        for attempt in range(25):
            try:
                return super().command(*command)
            except PermissionError:
                if attempt == 24:
                    raise
                time.sleep(.01)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
    parser.add_argument('--python', type=Path, default=ROOT / '.venv/Scripts/python.exe')
    parser.add_argument('--upstream', type=Path, default=ROOT / '.local/upstream/syncplay-1.7.6')
    parser.add_argument('--plugin', type=Path, default=ROOT / 'build/splay_core.dll')
    parser.add_argument('--media', default=str(ROOT / '.local/test-media.mp4'))
    args = parser.parse_args()
    directory = ROOT / '.local/integration' / ('playlist-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    directory.mkdir(parents=True)
    env = os.environ.copy()
    env.update(APPDATA=str(directory / 'appdata'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
    Path(env['APPDATA']).mkdir()
    job, processes, logs = Job(), [], []

    def launch(name, command, stdin=False):
        log = (directory / (name + '.log')).open('w', encoding='utf-8')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=args.upstream, env=env,
                                   stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        processes.append(process)
        return process

    def cli_command(command):
        cli.stdin.write(command + '\n')
        cli.stdin.flush()

    def state():
        return plugin.read()['state']

    def playlist():
        return state().get('playlist', {})

    def log_text():
        return (directory / 'official.log').read_text(encoding='utf-8', errors='replace')

    def room_snapshot(room, set_values=None):
        """Read the server's authoritative pre-Hello playlist and current List."""
        with socket.create_connection(('127.0.0.1', port), timeout=5) as probe:
            with probe.makefile('rwb', buffering=0) as stream:
                hello = {'username': 'probe-' + uuid.uuid4().hex[:6], 'room': {'name': room},
                         'version': '1.2.255', 'realversion': '1.7.6', 'features': {'sharedPlaylists': True}}
                stream.write(json.dumps({'Hello': hello}).encode() + b'\r\n')
                result = {'files': [], 'index': None}
                while True:
                    message = json.loads(stream.readline())
                    settings = message.get('Set', {})
                    if 'playlistChange' in settings:
                        result['files'] = settings['playlistChange']['files']
                    if 'playlistIndex' in settings:
                        result['index'] = settings['playlistIndex']['index']
                    if 'Hello' in message:
                        break
                if set_values is not None:
                    stream.write(json.dumps({'Set': set_values}).encode() + b'\r\n')
                    while True:
                        changed = json.loads(stream.readline()).get('Set', {})
                        if all(key in changed for key in set_values):
                            if 'playlistChange' in changed:
                                result['files'] = changed['playlistChange']['files']
                            if 'playlistIndex' in changed:
                                result['index'] = changed['playlistIndex']['index']
                            break
                stream.write(b'{"List":null}\r\n')
                while True:
                    listing = json.loads(stream.readline()).get('List')
                    if listing is not None:
                        result['members'] = listing.get(room, {})
                        return result

    def official_lists(files, selected=None):
        offset = len(log_text())
        last_query = 0
        def printed():
            nonlocal last_query
            # The plugin's echo can arrive before the official client's echo.
            # Query again while waiting instead of assuming both sockets have
            # consumed a broadcast at the same time.
            if time.monotonic() - last_query >= .5:
                cli_command('playlist')
                last_query = time.monotonic()
            output = log_text()[offset:]
            return all(('{}: {}'.format(i + 1, filename)) in output for i, filename in enumerate(files)) and (
                selected is None or ' *\t{}: {}'.format(selected + 1, files[selected]) in output)
        wait_for('unmodified official client displays the authoritative playlist' +
                 ('' if selected is None else ' and selected index'), printed)

    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        launch('server', [args.python, args.upstream / 'syncplayServer.py', '--port', port,
                         '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'playlist-fixture-salt'])
        def listening():
            with socket.socket() as client:
                return client.connect_ex(('127.0.0.1', port)) == 0
        wait_for('unmodified official server listens locally', listening)
        official, plugin = Player(directory, 'official'), Player(directory, 'plugin')
        room = 'playlist-' + uuid.uuid4().hex[:8]
        cli = launch('official', [args.python, args.upstream / 'syncplayClient.py', '--no-gui', '--no-store',
                                 '--host', '127.0.0.1:' + str(port), '--name', 'official', '--room', room,
                                 '--player-path', args.mpv, args.media, '--', '--vo=null', '--ao=null',
                                 '--pause=yes', '--no-config', '--scripts-append=' + str(official.script)], stdin=True)
        wait_for('official client owns a loaded real mpv', lambda: official.read().get('duration', 0) > 100)
        cli_command('queue official-中文-A.mkv')
        cli_command('queue official-😀-B.mkv')
        def seeded_snapshot():
            snapshot = room_snapshot(room)
            return snapshot if 'official-😀-B.mkv' in snapshot['files'] else False
        seeded = wait_for('official client seeds the room playlist before plugin login',
                          seeded_snapshot)
        launch('plugin', [args.mpv, '--no-config', '--vo=null', '--ao=null', '--pause=yes', '--idle=yes',
                          '--script=' + str(args.plugin), '--script=' + str(plugin.script), args.media])
        wait_for('plugin real mpv loads caller media', lambda: plugin.read().get('duration', 0) > 100)
        plugin.splay('connect', host='localhost', port=port, username='plugin', room=room, tls='off')
        wait_for('plugin retains the official pre-Hello playlist and index',
                 lambda: state().get('connection') == 'connected' and state().get('playlist_supported') is True
                 and playlist().get('files') == seeded['files'] and playlist().get('index') == seeded['index'])
        wait_for('member list displays the official public filename',
                 lambda: any(m['username'] == 'official' and m.get('file', {}).get('name') == Path(args.media).name
                             for m in state().get('members', [])))
        files = ['plugin-中文-1.mkv', 'plugin-😀-2.mkv']
        plugin.splay('playlist-set', files=files)
        wait_for('plugin playlist update receives authoritative server echo', lambda: playlist().get('files') == files)
        official_lists(files)
        plugin.splay('playlist-index', index=1)
        wait_for('plugin index update receives authoritative server echo', lambda: playlist().get('index') == 1)
        official_lists(files, selected=1)
        cli_command('select 1')
        wait_for('official client selected index reaches plugin', lambda: playlist().get('index') == 0 and playlist().get('user') == 'official')
        cli_command('queue official-added.mkv')
        files.append('official-added.mkv')
        wait_for('official client list update reaches plugin', lambda: playlist().get('files') == files)
        assert plugin.read()['path'] == args.media, 'Core playlist updates replaced caller media'
        print('PASS: playlist list/index round trip never loads media in plugin', flush=True)
        plugin.splay('playlist-index', index=999)
        wait_for('stale local index is a visible error without disconnect',
                 lambda: state().get('connection') == 'connected' and 'range' in state().get('error', ''))
        assert playlist()['index'] == 0
        maximum = ['maximum-' + str(i).zfill(3) + '-' + 'x' * 28 for i in range(250)]
        assert len(maximum) == 250 and sum(map(len, maximum)) == 10000
        plugin.splay('playlist-set', files=maximum)
        wait_for('full official 250-entry/10000-character ASCII playlist round trips',
                 lambda: state().get('connection') == 'connected' and playlist().get('files') == maximum)
        official_lists(maximum)
        assert room_snapshot(room)['files'] == maximum
        plugin.splay('playlist-set', files=['😀' * 40] * 250)
        wait_for('Unicode exceeding upstream wire limit is rejected without disconnecting either client',
                 lambda: state().get('connection') == 'connected' and 'too large' in state().get('error', ''))
        assert playlist()['files'] == maximum
        official_lists(maximum)
        unicode_boundary = ['😀' * 4] * 250
        plugin.splay('playlist-set', files=unicode_boundary)
        wait_for('250-entry Unicode playlist within upstream wire limit round trips',
                 lambda: playlist().get('files') == unicode_boundary)
        official_lists(unicode_boundary)
        plugin.splay('playlist-set', files=files)
        wait_for('restore short playlist after boundary check', lambda: playlist().get('files') == files)
        second = room + '-second'
        plugin.splay('room', room=second)
        wait_for('switching rooms clears the old shared playlist', lambda: state().get('room') == second and playlist().get('files') == [])
        cli_command('queue original-room-only.mkv')
        wait_for('official original room retains its independent list', lambda: 'original-room-only.mkv' in room_snapshot(room)['files'])
        plugin.splay('playlist-set', files=['second-room-only.mkv'])
        wait_for('second room has its own authoritative playlist', lambda: playlist().get('files') == ['second-room-only.mkv'])
        assert 'second-room-only.mkv' not in room_snapshot(room)['files']
        print('PASS: list and index updates are isolated by room', flush=True)
        # The unmodified server permits arbitrary indices from another member.
        # Exercise that incoming fault in the isolated room so the official
        # client's own unchecked index handling is not involved.
        room_snapshot(second, {'playlistIndex': {'index': 999}})
        wait_for('incoming stale server index reports an error while preserving connection and valid state',
                 lambda: state().get('connection') == 'connected' and 'range' in state().get('error', '')
                 and playlist().get('index') is None)
        plugin.splay('playlist-index', index=0)
        wait_for('valid authoritative index recovers after malformed server update', lambda: playlist().get('index') == 0)
        plugin.splay('disconnect')
        wait_for('disconnect clears playlist support and contents', lambda: state().get('connection') == 'disconnected' and playlist().get('files') == [] and not state().get('playlist_supported'))
        plugin.splay('connect', host='localhost', port=port, username='plugin', room=room, tls='off')
        expected = files + ['original-room-only.mkv']
        wait_for('reconnect replaces old room playlist with server snapshot', lambda: state().get('connection') == 'connected' and playlist().get('files') == expected)

        plugin.splay('create-room', room='ctl-' + uuid.uuid4().hex[:8], password='AA-123-456')
        controlled = wait_for('plugin creates controlled room and authenticates',
                              lambda: state().get('controlled') and state().get('is_controller') and state().get('room'))
        cli_command('r ' + controlled)
        wait_for('official joins controlled room as ordinary member',
                 lambda: any(m['username'] == 'official' and m['room'] == controlled for m in state().get('members', [])))
        controlled_files = ['controlled-1.mkv', 'controlled-2.mkv']
        plugin.splay('playlist-set', files=controlled_files)
        wait_for('room operator can update playlist', lambda: playlist().get('files') == controlled_files)
        plugin.splay('playlist-index', index=1)
        wait_for('room operator can select playlist index', lambda: playlist().get('index') == 1)
        cli_command('queue forbidden-ordinary-entry.mkv')
        time.sleep(.5)
        assert room_snapshot(controlled)['files'] == controlled_files
        assert playlist()['files'] == controlled_files
        print('PASS: official server rejects ordinary client playlist changes', flush=True)
        cli_command('auth AA-123-456')
        wait_for('official authenticates as controller', lambda: any(m['username'] == 'official' and m.get('is_controller') for m in state().get('members', [])))
        plugin.splay('room', room=second)
        wait_for('plugin leaves controlled room', lambda: state().get('room') == second)
        plugin.splay('room', room=controlled)
        wait_for('plugin returns as ordinary controlled-room member', lambda: state().get('room') == controlled and state().get('is_controller') is False and playlist().get('files') == controlled_files)
        plugin.splay('playlist-set', files=['forbidden-plugin-entry.mkv'])
        wait_for('ordinary plugin playlist edit reports permission error', lambda: 'operators' in state().get('error', '') and state().get('connection') == 'connected')
        plugin.splay('playlist-index', index=0)
        wait_for('ordinary plugin index edit reports permission error', lambda: 'operators' in state().get('error', '') and state().get('connection') == 'connected')
        assert room_snapshot(controlled)['files'] == controlled_files
        assert playlist()['index'] == 1
        # Readiness belongs to the user even when playback control is restricted.
        official.command('set', 'pause', 'yes')
        wait_for('operator establishes paused room', lambda: plugin.read().get('paused') is True)
        plugin.splay('ready', ready=False)
        wait_for('ordinary plugin readiness starts false', lambda: state().get('ready') is False)
        if not any(m['username'] == 'official' and m.get('ready') is True for m in state().get('members', [])):
            cli_command('t')
        wait_for('official operator is ready before requesting playback',
                 lambda: any(m['username'] == 'official' and m.get('ready') is True for m in state().get('members', [])))
        last_unpause = 0
        def operator_unpaused():
            nonlocal last_unpause
            # The official client suppresses unpause briefly after a room
            # rewind. Repeat the actual player action through that cooldown.
            if time.monotonic() - last_unpause >= .5 and official.read().get('paused') is True:
                official.command('set', 'pause', 'no')
                last_unpause = time.monotonic()
            return plugin.read().get('paused') is False
        wait_for('remote operator unpause reaches ordinary plugin', operator_unpaused)
        time.sleep(.3)
        assert state()['ready'] is False, 'Remote unpause falsely marked user ready'
        official.command('set', 'pause', 'yes')
        wait_for('operator pauses room for explicit local action', lambda: plugin.read().get('paused') is True)
        plugin.command('set', 'pause', 'no')
        wait_for('ordinary member explicit local unpause marks self ready', lambda: state().get('ready') is True)
        assert official.read().get('paused') is True, 'Ordinary member unexpectedly controlled room playback'
        plugin.command('set', 'pause', 'yes')
        time.sleep(.3)
        assert state()['ready'] is True, 'Pause unexpectedly cleared readiness'
        assert plugin.read()['path'] == args.media
        result = {'syncplay': '1.7.6', 'playlist_limit': {'items': 250, 'characters': 10000,
                  'upstream_server_echo_bytes': 16384, 'incoming_line_bytes': 131072},
                  'final_state': state(), 'plugin_path_preserved': plugin.read()['path'] == args.media}
        (directory / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: ordinary controlled member auto-ready is local-only and pause preserves readiness', flush=True)
        print('Artifacts:', directory, flush=True)
    finally:
        job.close()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
