"""Real mpv RTT sharing against unmodified Syncplay 1.7.6 server/client.

Two native clients exercise opt-in, withdrawal and empty media. The official
client remains unmodified; its actual console output checks that repeated
unknown file metadata does not become a file-change notification. Artifacts
and all synthetic settings stay under .local/integration.
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
    output = ROOT / '.local/integration' / ('latency-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    output.mkdir(parents=True)
    (output / 'peer').mkdir()
    env = dict(os.environ, APPDATA=str(output / 'appdata'), PYTHONUTF8='1',
               PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
    Path(env['APPDATA']).mkdir()
    job, processes, logs = Job(), [], []

    def launch(name, command, stdin=False):
        log = (output / (name + '.log')).open('w', encoding='utf-8')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=args.upstream, env=env,
                                   stdin=subprocess.PIPE if stdin else subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, text=True,
                                   encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        processes.append(process)
        return process

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    room = 'latency-' + uuid.uuid4().hex[:8]
    official, plugin = Player(output, 'official'), Player(output, 'plugin')
    peer = Player(output / 'peer', 'plugin')

    def state(player=plugin):
        return player.read()['state']

    def member(name, player=plugin):
        return next((value for value in state(player).get('members', []) if value['username'] == name), {})

    # Round-trip times arrive in splay-latency, apart from the state: the
    # player's own under "self", and only members that reported one by name.
    def latency(player=plugin):
        return player.read()['latency']

    def own(player=plugin):
        return latency(player).get('self') or {}

    def report(name, player=plugin):
        return (latency(player).get('members') or {}).get(name) or {}

    def log_text():
        return (output / 'official.log').read_text(encoding='utf-8', errors='replace')

    def cli_command(command):
        cli.stdin.write(command + '\n')
        cli.stdin.flush()

    def server_members():
        with socket.create_connection(('127.0.0.1', port), timeout=5) as probe:
            with probe.makefile('rwb', buffering=0) as stream:
                stream.write(json.dumps({'Hello': {'username': 'audit-' + uuid.uuid4().hex[:6],
                    'room': {'name': 'isolated-audit'}, 'version': '1.2.255', 'realversion': '1.7.6'}}).encode() + b'\r\n')
                while 'Hello' not in json.loads(stream.readline()):
                    pass
                stream.write(b'{"List":null}\r\n')
                while True:
                    value = json.loads(stream.readline()).get('List')
                    if value is not None:
                        return value.get(room, {})

    try:
        launch('server', [args.python, args.upstream / 'syncplayServer.py', '--port', port,
                         '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'synthetic-latency-fixture'])

        def listening():
            with socket.socket() as probe:
                return probe.connect_ex(('127.0.0.1', port)) == 0

        wait_for('unmodified official server listens', listening)
        cli = launch('official', [args.python, args.upstream / 'syncplayClient.py', '--no-gui', '--no-store',
            '--language', 'en', '--host', '127.0.0.1:' + str(port), '--name', 'official', '--room', room,
            '--player-path', args.mpv, args.media, '--', '--vo=null', '--ao=null', '--pause=yes',
            '--no-config', '--scripts-append=' + str(official.script)], stdin=True)
        wait_for('official client owns actual loaded mpv', lambda: official.read().get('duration', 0) > 100)
        for name, player in [('plugin', plugin), ('peer', peer)]:
            launch(name, [args.mpv, '--no-config', '--vo=null', '--ao=null', '--pause=yes', '--idle=yes',
                          '--script=' + str(args.plugin), '--script=' + str(player.script), args.media])
            wait_for(name + ' loads caller media', lambda p=player: p.read().get('duration', 0) > 100)
            player.splay('connect', host='127.0.0.1', port=port, username=name, room=room, tls='off')
            wait_for(name + ' connects', lambda p=player: state(p).get('connection') == 'connected')
        wait_for('native List contains both peers and official client', lambda: len(state().get('members', [])) == 3)
        wait_for('latency is reported apart from the state, off by default',
                 lambda: latency().get('enabled') is False and latency(peer).get('enabled') is False)
        assert 'latency' not in state() and not any('latency' in value for value in state()['members'])
        baseline = server_members()
        for name in ('plugin', 'peer'):
            assert 'splayLatency' not in baseline[name]['file']
        wait_for('official client receives both initial hidden filenames',
                 lambda: "plugin is playing '" in log_text() and "peer is playing '" in log_text())
        notices_before = {name: log_text().count(name + " is playing '") for name in ('plugin', 'peer')}
        plugin.splay('latency', enabled=True)
        wait_for('first native measures RTT using official server heartbeat',
                 lambda: isinstance(own().get('rtt_ms'), (int, float)))
        wait_for('first native shares optional metadata',
                 lambda: server_members()['plugin']['file'].get('splayLatency'))
        assert member('peer') and member('official') and not latency()['members'], latency()
        peer.splay('latency', enabled=True)
        wait_for('two opted-in native clients see each other reported RTT',
                 lambda: isinstance(report('peer').get('rtt_ms'), (int, float))
                 and isinstance(report('plugin', peer).get('rtt_ms'), (int, float)))
        plugin.splay('ready', ready=True)
        wait_for('explicit readiness is set before repeated metadata', lambda: state()['ready'] is True)
        before = server_members()
        before_seq = before['plugin']['file']['splayLatency']['seq']
        event_baseline = max((event.get('id', 0) for event in plugin.read()['events']), default=0)

        def repeated_share():
            members = server_members()
            report = members['plugin']['file'].get('splayLatency', {})
            return members if report.get('seq', 0) > before_seq else False

        after = wait_for('real periodic metadata crosses unmodified server again', repeated_share, seconds=16)
        for name in ('plugin', 'peer'):
            original, updated = before[name]['file'], after[name]['file']
            assert {key: updated[key] for key in ('name', 'duration', 'size')} == {
                key: original[key] for key in ('name', 'duration', 'size')}
            assert set(updated['splayLatency']) == {'v', 'rtt_ms', 'seq', 'session'}
        assert after['plugin']['isReady'] is True and state()['ready'] is True
        assert notices_before == {name: log_text().count(name + " is playing '") for name in ('plugin', 'peer')}, log_text()
        assert all(event.get('action') != 'file' for event in plugin.read()['events']
                   if event.get('username') == 'peer' and event.get('id', 0) > event_baseline)
        assert 'splayLatency' not in member('peer')['file']
        assert report('peer')['self_reported'] is True and 'official' not in latency()['members']
        offset = len(log_text())
        cli_command('list')
        wait_for('unmodified official client still displays members and readiness normally',
                 lambda: '(Ready) <plugin> is playing:' in log_text()[offset:]
                 and '<peer> is playing:' in log_text()[offset:])
        official.command('seek', '30', 'absolute')
        wait_for('official seek still synchronizes both opted-in natives',
                 lambda: abs(plugin.read().get('position', 0)-30) < 2 and abs(peer.read().get('position', 0)-30) < 2)
        assert plugin.read()['path'] == args.media and peer.read()['path'] == args.media
        plugin.splay('latency', enabled=False)
        wait_for('disabling sharing removes metadata without changing basic file',
                 lambda: 'splayLatency' not in server_members()['plugin']['file'])
        wait_for('other opted-in native sees immediate withdrawal as unreported',
                 lambda: 'plugin' not in (latency(peer).get('members') or {}))
        # The observer rewrites its snapshot every 100 ms, and the peer can now
        # show the withdrawal before this player's next snapshot is on disk.
        wait_for('disabling sharing clears own displayed RTT', lambda: latency().get('enabled') is False and own().get('rtt_ms') is None)
        peer.command('stop')
        wait_for('empty media sends no fake file metadata', lambda: server_members()['peer'].get('file') == {})
        wait_for('own RTT remains measurable while no media is loaded',
                 lambda: isinstance(own(peer).get('rtt_ms'), (int, float)))
        plugin.splay('latency', enabled=True)
        wait_for('remaining peer gets an explicitly re-enabled valid report',
                 lambda: isinstance(report('plugin', peer).get('rtt_ms'), (int, float)))
        plugin.splay('room', room=room + '-other')
        wait_for('room change clears peer reports',
                 lambda: state()['room'] == room + '-other' and not latency()['members'])
        result = {'passed': True, 'official_version': '1.7.6',
            'default_off': True, 'two_native_heartbeat_rtts': True, 'periodic_metadata': True,
            'official_file_notice_count_unchanged': notices_before, 'official_list_and_ready': True,
            'official_seek_and_media_preserved': True, 'withdrawal': True, 'empty_media_no_fake_file': True,
            'final_native_state': state(), 'final_native_latency': latency()}
        (output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: latency interoperability and official-client metadata compatibility:', output, flush=True)
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
