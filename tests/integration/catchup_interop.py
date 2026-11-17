"""Smooth catch-up on real mpv against unmodified Syncplay 1.7.6 server and client.

The official server's room clock follows its slowest watcher. Slowing the
official client's own mpv makes the plugin drift ahead of the room by a
controlled amount, which is the situation the catch-up handles: the plugin
slows to 0.95x instead of jumping back, returns to 1x once level, still
rewinds a larger lead, never overrides a speed the user chose, restores 1x
when it leaves the room, and does not let a quit save its slowed speed into
mpv's watch-later file. Everything stays under .local/integration.
"""
import argparse
import json
import os
from pathlib import Path
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
    parser.add_argument('--media', default=str(ROOT / '.local/test-media.mp4'))
    args = parser.parse_args()
    output = ROOT / '.local/integration' / ('catchup-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    output.mkdir(parents=True)
    watch_later = output / 'watch-later'
    watch_later.mkdir()
    env = dict(os.environ, APPDATA=str(output / 'appdata'), PYTHONUTF8='1',
               PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
    Path(env['APPDATA']).mkdir()
    job, logs, findings = Job(), [], []

    def launch(name, command):
        log = (output / (name + '.log')).open('w', encoding='utf-8')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=args.upstream, env=env, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        return process

    def note(text, **values):
        findings.append(dict(step=text, **values))
        print('OK:', text, json.dumps(values) if values else '', flush=True)

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    room = 'catchup-' + uuid.uuid4().hex[:8]
    official, plugin = Player(output, 'official'), Player(output, 'plugin')

    def state():
        return plugin.read()['state']

    def speed(player=plugin):
        return player.read().get('speed')

    def position(player=plugin):
        return player.read().get('position') or 0

    def lead():
        return position(plugin) - position(official)

    def watch_later_lists_speed():
        return 'speed' in (plugin.read().get('watch_later_options') or '').split(',')

    def catchup_events(action):
        return [event for event in plugin.read()['events'] if event.get('type') == 'catchup' and event.get('action') == action]

    def official_speed(value):
        official.command('set', 'speed', str(value))
        wait_for('official mpv plays at %s' % value, lambda: abs((speed(official) or 0) - value) < .001)

    def level(description):
        # Back to a common clock at 1x before the next case. A room seek aligns
        # at once instead of waiting for a 5% catch-up. It comes from the
        # plugin: the official client does not always report a seek of its own
        # player, but always follows one from the room.
        official_speed(1)
        plugin.command('seek', '%.3f' % (position(official) + 2), 'absolute+exact')
        wait_for(description, lambda: speed() == 1 and abs(lead()) < .6, seconds=20)

    def follow(description, predicate, seconds, rewind=False, slowed=None):
        """Sample the plugin until predicate holds.

        Without rewind, any jump back fails the wait. With rewind, a jump back
        must have happened before predicate counts. slowed=False forbids 0.95x.
        """
        until = time.monotonic() + seconds
        previous, jumped = position(), False
        while time.monotonic() < until:
            snapshot = plugin.read()
            current = snapshot.get('position') or 0
            if current < previous - .5:
                assert rewind, ('the plugin jumped back', previous, current)
                jumped = True
            assert slowed is not False or snapshot.get('speed') == 1, ('the plugin changed speed', snapshot.get('speed'))
            previous = current
            if (jumped or not rewind) and predicate():
                print('PASS:', description, flush=True)
                return
            time.sleep(.1)
        a, b = plugin.read(), official.read()
        raise AssertionError('Timed out: %s; plugin position=%s paused=%s speed=%s catchup=%s warning=%r; '
                             'official position=%s paused=%s speed=%s' % (description, a.get('position'), a.get('paused'),
                             a.get('speed'), a['state'].get('catchup'), a['state'].get('warning'),
                             b.get('position'), b.get('paused'), b.get('speed')))

    def slow_down(rate=.8):
        official_speed(rate)
        start = len(catchup_events('slow'))
        follow('the plugin slows to 0.95x instead of jumping back',
               lambda: speed() == .95 and len(catchup_events('slow')) > start, 30)
        assert 1.3 < lead() < 4.2, lead()
        assert not state().get('warning'), state().get('warning')
        assert state()['catchup']['active'] is True
        assert not watch_later_lists_speed(), plugin.read().get('watch_later_options')

    try:
        launch('server', [args.python, args.upstream / 'syncplayServer.py', '--port', port,
                          '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'synthetic-catchup-fixture'])

        def listening():
            with socket.socket() as probe:
                return probe.connect_ex(('127.0.0.1', port)) == 0

        wait_for('unmodified official server listens', listening)
        start_official(lambda: launch('official', [args.python, args.upstream / 'syncplayClient.py', '--no-gui', '--no-store',
            '--language', 'en', '--host', '127.0.0.1:' + str(port), '--name', 'official', '--room', room,
            '--player-path', args.mpv, args.media, '--', '--vo=null', '--ao=null', '--pause=yes',
            '--no-config', '--scripts-append=' + str(official.script)]),
                             official, output / 'official.log', 'official client owns actual loaded mpv')
        player = launch('plugin', [args.mpv, '--no-config', '--vo=null', '--ao=null', '--pause=yes', '--idle=yes',
                                   '--save-position-on-quit', '--watch-later-dir=' + str(watch_later),
                                   '--script=' + str(args.plugin), '--script=' + str(plugin.script), args.media])
        wait_for('plugin loads caller media', lambda: plugin.read().get('duration', 0) > 100)
        assert watch_later_lists_speed()
        plugin.splay('room-policy', pause_on_join=False, pause_on_leave=False)
        plugin.splay('connect', host='127.0.0.1', port=port, username='plugin', room=room, tls='off')
        wait_for('plugin connects', lambda: state().get('connection') == 'connected')
        assert state()['catchup'] == {'enabled': True, 'active': False}, state()['catchup']
        time.sleep(1.5)  # the adapter ignores local changes in the first second of a connection
        plugin.command('seek', '20', 'absolute+exact')
        wait_for('both players at 20', lambda: abs(position() - 20) < .5 and abs(position(official) - 20) < 1)
        plugin.command('set', 'pause', 'no')
        wait_for('both players play together', lambda: not plugin.read()['paused'] and not official.read()['paused']
                 and abs(lead()) < .6, seconds=20)
        note('plugin and official client play in step at 1x', lead=round(lead(), 3))

        # 1. A small lead: slow down, then back to 1x once level.
        slow_down()
        note('a lead past 1.5 s slows the plugin to 0.95x without a jump back', lead=round(lead(), 3))
        official_speed(1.1)
        follow('the plugin is level again and back at 1x', lambda: speed() == 1 and catchup_events('normal'), 40)
        official_speed(1)
        assert abs(lead()) < .6 and watch_later_lists_speed(), (lead(), plugin.read().get('watch_later_options'))
        note('caught up: back at 1x and level with the room', lead=round(lead(), 3))

        # 2. A lead that keeps growing past 4 s is rewound, as before.
        official_speed(.5)
        wait_for('the plugin slows first', lambda: speed() == .95, 30)
        follow('a lead above 4 s is rewound and 1x restored', lambda: speed() == 1 and abs(lead()) < 1, 40, rewind=True)
        level('level again after the rewind')
        note('a growing lead is rewound once it passes 4 s')

        # 3. A speed the user chooses is never overridden.
        slow_down()
        plugin.command('set', 'speed', '1.25')
        wait_for('sync is suspended for the user speed', lambda: 'speed' in (state().get('warning') or ''), 10)
        official_speed(1)
        time.sleep(3)
        assert speed() == 1.25 and state()['catchup']['active'] is False, (speed(), state()['catchup'])
        assert watch_later_lists_speed()
        plugin.command('set', 'speed', '1')
        wait_for('sync resumes at 1x', lambda: not state().get('warning'), 10)
        level('level again after the user speed')
        note('a user speed during a catch-up is left alone and synchronization waits for 1x')

        # 4. Switched off, a lead past 1.5 s is sought back as before.
        plugin.splay('catchup', enabled=False)
        wait_for('catch-up off in the state', lambda: state()['catchup']['enabled'] is False)
        official_speed(.8)
        follow('without catch-up the lead is sought back at 1x', lambda: abs(lead()) < .8, 30, rewind=True, slowed=False)
        plugin.splay('catchup', enabled=True)
        wait_for('catch-up on again', lambda: state()['catchup']['enabled'] is True)
        level('level again with catch-up back on')
        note('switched off, the plugin seeks as before and never changes speed')

        # 5. Leaving the room restores 1x.
        slow_down()
        plugin.splay('disconnect')
        wait_for('leaving the room restores 1x', lambda: speed() == 1 and state().get('connection') == 'disconnected', 10)
        assert watch_later_lists_speed()
        note('disconnecting during a catch-up restores 1x and the watch-later options')
        official_speed(1)
        plugin.splay('connect', host='127.0.0.1', port=port, username='plugin', room=room, tls='off')
        wait_for('plugin rejoins', lambda: state().get('connection') == 'connected')
        # Joining pauses the room by default; resume, as a user would.
        time.sleep(1.5)
        plugin.command('set', 'pause', 'no')
        wait_for('level after rejoining', lambda: abs(lead()) < .6 and not plugin.read()['paused'], 30)

        # 6. Quitting during a catch-up does not save the slowed speed.
        slow_down()
        plugin.command('quit')
        player.wait(timeout=10)
        saved = [path for path in watch_later.iterdir() if path.is_file()]
        lines = [line for path in saved for line in path.read_text(encoding='utf-8', errors='replace').splitlines()
                 if not line.startswith('#')]
        assert any(line.startswith('start=') for line in lines), lines
        assert not any(line.startswith('speed=') for line in lines), lines
        note('quitting during a catch-up saves the position but not the slowed speed', saved=lines)

        (output / 'result.json').write_text(json.dumps({'passed': True, 'official_version': '1.7.6',
            'findings': findings}, indent=2), encoding='utf-8')
        print('PASS: smooth catch-up against the unmodified official client and server:', output, flush=True)
    finally:
        job.close()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
