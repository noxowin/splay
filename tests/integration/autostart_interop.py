"""Autostart against unmodified Syncplay 1.7.6 and two real mpv players.

Run only after building the native plugin. All ports, rooms, credentials,
configuration and logs are synthetic and isolated. A Windows kill-on-close Job
owns the server, official client and their player descendants.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import uuid

from interop import Job, start_official, Player as ObserverPlayer, ROOT, wait_for


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
    parser.add_argument('--media', type=Path, default=ROOT / '.local/test-media.mp4')
    args = parser.parse_args()
    output = ROOT / '.local' / ('autostart-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    output.mkdir(parents=True)
    env = dict(os.environ, APPDATA=str(output / 'appdata'), PYTHONUTF8='1',
               PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
    Path(env['APPDATA']).mkdir()
    job, processes, logs = Job(), [], []
    official, plugin = Player(output, 'official'), Player(output, 'plugin')
    cases = []
    room = 'autostart-' + uuid.uuid4().hex[:8]
    password = 'synthetic-server-' + uuid.uuid4().hex
    operator_password = 'AA-123-456'
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]

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

    def state():
        return plugin.read()['state']

    def auto():
        return state().get('autostart', {})

    def member(name):
        snapshot = state()
        return next((m for m in snapshot.get('members', [])
                     if m['username'] == name and m.get('room') == snapshot.get('room')), {})

    def cli_command(command):
        cli.stdin.write(command + '\n')
        cli.stdin.flush()

    def ready_official(value):
        wait_for('official member is visible before readiness command', lambda: member('official'))
        if member('official').get('ready') is not value:
            cli_command('t')
        wait_for('official readiness becomes ' + str(value), lambda: member('official').get('ready') is value)

    def both_paused(value=True):
        return official.read().get('paused') is value and plugin.read().get('paused') is value

    def hold(description, predicate, seconds=3.6):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            assert predicate(), description + ': ' + json.dumps(plugin.read(), ensure_ascii=False)
            time.sleep(.1)
        print('PASS:', description, flush=True)

    def record(name):
        cases.append({'case': name, 'passed': True, 'autostart': auto(),
                      'plugin': {k: plugin.read().get(k) for k in ('paused', 'path', 'position')},
                      'official': {k: official.read().get(k) for k in ('paused', 'path', 'position')}})
        (output / 'cases.json').write_text(json.dumps(cases, ensure_ascii=False, indent=2), encoding='utf-8')

    def prepare():
        plugin.splay('autostart', enabled=False)
        wait_for('autostart disabled for next independent scenario', lambda: auto().get('enabled') is False and not auto().get('pending'))
        plugin.command('set', 'pause', 'yes')
        wait_for('both actual players are paused', both_paused)
        plugin.splay('ready', ready=True)
        wait_for('native readiness round trips', lambda: state().get('ready') is True)
        ready_official(True)
        wait_for('both members advertise loaded media', lambda: member('official').get('file') and member('plugin').get('file'))

    def arm(delay=3):
        plugin.splay('autostart', enabled=True, delay=delay)
        wait_for('all-ready native timer is pending', lambda: auto().get('pending') is True and auto().get('reason') == 'countdown')
        current = auto()
        assert current['delay'] == delay and 0 < current['remaining'] <= delay, current
        assert current['participants'] == 2, current
        return time.monotonic()

    def connect(target_room):
        plugin.splay('connect', host='127.0.0.1', port=port, username='plugin',
                     room=target_room, password=password, tls='off', auto_reconnect=True)
        wait_for('native plugin connects to official server', lambda: state().get('connection') == 'connected' and state().get('room') == target_room)

    def server_members(target_room):
        # Audit in a separate room so this read-only observer cannot satisfy or
        # invalidate the room's minimum-participant condition.
        with socket.create_connection(('127.0.0.1', port), timeout=5) as probe:
            with probe.makefile('rwb', buffering=0) as stream:
                stream.write(json.dumps({'Hello': {'username': 'audit-' + uuid.uuid4().hex[:6],
                    'password': hashlib.md5(password.encode()).hexdigest(),
                    'room': {'name': 'isolated-audit'}, 'version': '1.2.255', 'realversion': '1.7.6'}}).encode() + b'\r\n')
                while 'Hello' not in json.loads(stream.readline()):
                    pass
                stream.write(b'{"List":null}\r\n')
                while True:
                    listing = json.loads(stream.readline()).get('List')
                    if listing is not None:
                        return listing.get(target_room, {})

    server_command = [args.python, args.upstream / 'syncplayServer.py', '--port', port,
                      '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt',
                      'synthetic-autostart-salt', '--password', password]
    try:
        server = launch('server', server_command)

        def listening():
            with socket.socket() as probe:
                return probe.connect_ex(('127.0.0.1', port)) == 0

        wait_for('unmodified official 1.7.6 server listens only on loopback', listening)
        cli = start_official(lambda: launch('official', [args.python, args.upstream / 'syncplayClient.py', '--no-gui',
            '--no-store', '--language', 'en', '--host', '127.0.0.1:' + str(port),
            '--password', password, '--name', 'official', '--room', room,
            '--player-path', args.mpv, args.media, '--', '--vo=null', '--ao=null',
            '--pause=yes', '--no-config', '--scripts-append=' + str(official.script)], stdin=True),
                             official, output / 'official.log', 'unmodified official client owns real loaded mpv')
        wait_for('official client completes its delayed initial file announcement', lambda:
                 "official is playing '" in (output / 'official.log').read_text(encoding='utf-8', errors='replace'))
        # Upstream starts mpv first and applies its initial room state later.
        # Stabilize that existing startup path before testing native behavior.
        time.sleep(2)
        official.command('set', 'pause', 'yes')
        wait_for('official initial pause settles before native joins', lambda: official.read().get('paused') is True)
        time.sleep(1)
        launch('native-mpv', [args.mpv, '--no-config', '--load-scripts=no', '--vo=null', '--ao=null',
            '--pause=yes', '--idle=yes', '--script=' + str(args.plugin),
            '--script=' + str(plugin.script), args.media])
        wait_for('native plugin loads caller media while disconnected', lambda: plugin.read().get('duration', 0) > 100 and state().get('connection') == 'disconnected')
        assert auto().get('enabled') is False and auto().get('delay') == 5, auto()
        connect(room)
        wait_for('two actual clients are visible', lambda: len(state().get('members', [])) == 2)
        baseline_paths = [plugin.read()['path'], official.read()['path']]
        prepare()
        hold('all-ready default-off leaves both real players paused', lambda: both_paused() and not auto().get('pending'))
        record('default-off')

        ready_official(False)
        plugin.splay('autostart', enabled=True, delay=3)
        wait_for('unready official member blocks native timer', lambda: auto().get('reason') == 'waiting-ready' and not auto().get('pending'))
        hold('official member not ready never starts either real player', lambda: both_paused() and not auto().get('pending'))
        record('official-not-ready')
        ready_official(True)
        wait_for('official readiness starts countdown', lambda: auto().get('pending'))
        countdown_at = time.monotonic()
        positions_before_play = [plugin.read()['position'], official.read()['position']]
        wait_for('native countdown actually unpauses both players', lambda: both_paused(False), seconds=10)
        assert time.monotonic() - countdown_at >= 2.2, 'Autostart bypassed configured three-second delay'
        wait_for('both actual player clocks advance after automatic play', lambda:
                 plugin.read().get('position', 0) > positions_before_play[0] + .5
                 and official.read().get('position', 0) > positions_before_play[1] + .5
                 and abs(plugin.read()['position'] - official.read()['position']) < 2)
        wait_for('one-shot autostart emits its explicit started event', lambda:
                 not auto().get('pending') and any(event.get('type') == 'autostart'
                     and event.get('action') == 'started' for event in plugin.read()['events']))
        wait_for('one-shot autostart retains started reason after official echo', lambda:
                 auto().get('reason') == 'started' and not auto().get('pending'))
        hold('official playback echo preserves started reason', lambda:
             auto().get('reason') == 'started' and not auto().get('pending'), seconds=1.2)
        assert [plugin.read()['path'], official.read()['path']] == baseline_paths
        assert all(v['isReady'] is True for v in server_members(room).values())
        record('all-ready-countdown-real-unpause-media-preserved')
        plugin.command('set', 'pause', 'yes')
        wait_for('manual pause propagates after automatic play', both_paused)
        hold('same all-ready phase does not repeatedly unpause after manual pause', lambda: both_paused() and not auto().get('pending'))
        record('no-repeat-after-manual-pause')

        prepare()
        arm()
        plugin.splay('autostart-cancel')
        wait_for('explicit cancel removes pending countdown', lambda: not auto().get('pending'))
        hold('cancel keeps both paused throughout former deadline', lambda: both_paused() and not auto().get('pending'))
        record('cancel-countdown')
        plugin.splay('ready', ready=False)
        wait_for('cancelled phase sees explicit unready reset', lambda: state().get('ready') is False)
        plugin.splay('ready', ready=True)
        wait_for('false then true readiness permits a fresh countdown', lambda: auto().get('pending'))
        plugin.splay('autostart-cancel')
        wait_for('fresh countdown can also be cancelled', lambda: not auto().get('pending'))
        record('ready-cycle-rearms-cancelled-phase')

        prepare()
        arm()
        ready_official(False)
        wait_for('official ready withdrawal cancels countdown', lambda: not auto().get('pending'))
        hold('ready withdrawal prevents playback at former deadline', lambda: both_paused() and not auto().get('pending'))
        record('ready-withdrawal')

        prepare()
        arm()
        cli_command('r ' + room + '-away')
        wait_for('official leaving cancels countdown with fewer than two members', lambda: not member('official') and not auto().get('pending'))
        hold('member departure prevents local automatic playback', lambda: plugin.read().get('paused') is True and not auto().get('pending'))
        record('member-leave')
        cli_command('r ' + room)
        wait_for('official rejoins original room', lambda: member('official'))

        prepare()
        arm()
        cli_command('p')
        wait_for('official manual play precedes countdown and reaches plugin', lambda: both_paused(False), seconds=2.5)
        wait_for('official manual play cancels native timer', lambda: not auto().get('pending'))
        record('official-play-cancels-countdown')

        prepare()
        arm()
        plugin.command('seek', 35, 'absolute+exact')
        wait_for('local seek cancels countdown', lambda: not auto().get('pending') and abs(plugin.read().get('position', 0) - 35) < 2)
        hold('manual seek suppresses playback through former deadline', lambda: both_paused() and not auto().get('pending'))
        record('manual-seek-cancels-countdown')

        prepare()
        arm()
        reload_media = output / ('synthetic-reload' + args.media.suffix)
        shutil.copyfile(args.media, reload_media)
        plugin.command('loadfile', str(reload_media))
        wait_for('loading another harness-owned media cancels countdown', lambda:
                 plugin.read().get('path') == str(reload_media) and not auto().get('pending'))
        plugin.command('set', 'pause', 'yes')
        wait_for('loaded replacement is paused in both players', both_paused)
        hold('media replacement suppresses pending automatic play', lambda: both_paused() and not auto().get('pending'))
        record('loadfile-cancels-countdown')
        plugin.splay('autostart', enabled=False)
        wait_for('disable is consumed before restoring original fixture', lambda: auto().get('enabled') is False)
        plugin.command('loadfile', str(args.media))
        wait_for('original caller fixture reloads', lambda: plugin.read().get('path') == str(args.media) and plugin.read().get('duration', 0) > 100)

        prepare()
        arm()
        plugin.command('stop')
        wait_for('stopping local media cancels countdown', lambda: plugin.read().get('path') is None and not auto().get('pending'))
        hold('empty local player never starts at former deadline', lambda: plugin.read().get('path') is None and not auto().get('pending'))
        assert not server_members(room)['plugin'].get('file')
        record('stop-cancels-countdown')
        plugin.splay('autostart', enabled=False)
        wait_for('disable is consumed before reloading stopped fixture', lambda: auto().get('enabled') is False)
        plugin.command('loadfile', str(args.media))
        wait_for('same local media reloads', lambda: plugin.read().get('duration', 0) > 100)

        prepare()
        arm()
        plugin.splay('room', room=room + '-native-away')
        wait_for('room change disables and cancels autostart', lambda: state().get('room') == room + '-native-away' and auto().get('enabled') is False and not auto().get('pending'))
        record('room-change-disables')
        plugin.splay('room', room=room)
        wait_for('native rejoins official room', lambda: state().get('room') == room and member('official'))

        prepare()
        arm()
        plugin.splay('disconnect')
        wait_for('manual disconnect disables and cancels autostart', lambda: state().get('connection') == 'disconnected' and auto().get('enabled') is False and not auto().get('pending'))
        connect(room)
        wait_for('manual reconnect keeps autostart disabled', lambda: auto().get('enabled') is False and member('official'))
        record('disconnect-reconnect-default-off')

        plugin.splay('create-room', room='autostart-ctl-' + uuid.uuid4().hex[:6], password=operator_password)
        controlled = wait_for('real controlled room creation authenticates native operator', lambda: state().get('controlled') and state().get('is_controller') and state().get('room'))
        cli_command('r ' + controlled)
        wait_for('official joins real controlled room', lambda: member('official') and member('official').get('room') == controlled)
        plugin.splay('disconnect')
        wait_for('native leaves controlled room', lambda: state().get('connection') == 'disconnected')
        connect(controlled)
        wait_for('rejoined native is ordinary controlled member', lambda: state().get('controlled') and not state().get('is_controller') and member('official'))
        prepare()
        plugin.splay('autostart', enabled=True, delay=3)
        wait_for('ordinary controlled member cannot arm autostart', lambda: auto().get('reason') == 'no-permission' and not auto().get('pending'))
        hold('ordinary controlled member cannot unpause actual players', lambda: both_paused() and not auto().get('pending'))
        record('controlled-ordinary-member-rejected')
        plugin.splay('authenticate', password=operator_password)
        wait_for('actual server grants native controller authentication', lambda: state().get('is_controller'))
        plugin.splay('autostart', enabled=True, delay=3)
        wait_for('authenticated controller can start pending countdown', lambda: auto().get('pending'))
        wait_for('authenticated controller automatically unpauses both real players', lambda: both_paused(False), seconds=10)
        assert [plugin.read()['path'], official.read()['path']] == baseline_paths
        record('controlled-authentication-allows-real-unpause')

        prepare()
        arm()
        server.terminate()
        server.wait(timeout=5)
        wait_for('actual server loss cancels autostart and resets enabled', lambda: state().get('connection') != 'connected' and auto().get('enabled') is False and not auto().get('pending'))
        server = launch('server-restarted', server_command)
        wait_for('official server restarts at same isolated endpoint', listening)
        wait_for('native automatic reconnect succeeds with autostart disabled', lambda: state().get('connection') == 'connected' and auto().get('enabled') is False and not auto().get('pending'), seconds=25)
        record('server-loss-auto-reconnect-default-off')
        result = {'passed': True, 'official_version': '1.7.6', 'plugin_sha256': hashlib.sha256(args.plugin.read_bytes()).hexdigest(),
                  'mpv': str(args.mpv), 'plugin': str(args.plugin), 'cases': cases, 'artifacts': str(output)}
        (output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: real autostart interoperability:', output, flush=True)
    except Exception as exc:
        (output / 'result.json').write_text(json.dumps({'passed': False, 'error': str(exc), 'cases': cases}, ensure_ascii=False, indent=2), encoding='utf-8')
        raise
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
        print('Artifacts:', output, flush=True)


if __name__ == '__main__':
    main()
