"""Restart unmodified Syncplay 1.7.6 under a real isolated mpv instance.

Uses developer-only IPC automation for the synthetic test passwords. Browser
integration is excluded. Only this harness's owned processes are terminated.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

from interop import Job, Player, ROOT, wait_for


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', type=Path, default=ROOT/'.local/mpv/runtime/mpv.exe')
    parser.add_argument('--plugin', type=Path, default=ROOT/'build/splay_core.dll')
    parser.add_argument('--python', type=Path, default=ROOT/'.venv/Scripts/python.exe')
    parser.add_argument('--upstream', type=Path, default=ROOT/'.local/upstream/syncplay-1.7.6')
    args = parser.parse_args()
    output = ROOT/'.local/reconnect-official'/('run-'+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    player = Player(output, 'plugin')
    player.script.write_text(player.script.read_text(encoding='utf-8').replace(
        "duration=mp.get_property_native('duration'), state=state",
        "duration=mp.get_property_native('duration'), speed=mp.get_property_native('speed'), state=state"), encoding='utf-8')
    env = dict(os.environ, APPDATA=str(output/'appdata'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    Path(env['APPDATA']).mkdir()
    job, processes, logs = Job(), [], []

    def launch(name, command, cwd=ROOT):
        log = (output/(name+'.log')).open('wb')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=cwd, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        processes.append(process)
        return process

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    server_password = 'synthetic-reconnect-'+uuid.uuid4().hex
    command = [args.python, args.upstream/'syncplayServer.py', '--port', port, '--ipv4-only',
               '--interface-ipv4', '127.0.0.1', '--salt', 'isolated-reconnect-fixture', '--password', server_password]

    def listening():
        with socket.socket() as probe:
            return probe.connect_ex(('127.0.0.1', port)) == 0

    def state():
        return player.read()['state']

    try:
        server = launch('server-first', command, args.upstream)
        wait_for('unmodified official server starts', listening)
        launch('mpv', [args.mpv, '--no-config', '--load-scripts=no', '--vo=null', '--ao=null',
                      '--idle=yes', '--pause=yes', '--speed=1.25', '--start=9',
                      '--script='+str(args.plugin), '--script='+str(player.script), ROOT/'.local/test-media.mp4'])
        wait_for('isolated mpv starts disconnected', lambda: state().get('connection') == 'disconnected')
        wait_for('media and caller playback options load', lambda: player.read().get('position') is not None)
        baseline = player.read()
        assert baseline['paused'] is True and baseline['speed'] == 1.25 and abs(baseline['position']-9) < .5
        player.splay('connect', host='127.0.0.1', port=port, username='official-reconnect', room='base',
                     password=server_password, tls='off', auto_reconnect=True)
        wait_for('official server accepts authenticated first Hello', lambda: state().get('connection') == 'connected')
        player.splay('create-room', room='reconnect', password='AA-123-456')
        wait_for('official server returns actual controlled room and operator permission',
                 lambda: state().get('controlled') and state().get('is_controller'))
        actual_room = state()['room']
        player.splay('ready', ready=True)
        wait_for('initial readiness established', lambda: state().get('ready') is True)
        server.terminate()
        server.wait(timeout=5)
        wait_for('actual server shutdown schedules automatic retry', lambda: state().get('reconnect', {}).get('pending'))
        launch('server-restarted', command, args.upstream)
        wait_for('same unmodified official server restarts', listening)
        wait_for('automatic reconnect completes authenticated Hello after server restart',
                 lambda: state().get('connection') == 'connected' and not state()['reconnect']['pending'])
        restored = state()
        assert restored['room'] == actual_room and restored['controlled'] is True
        assert restored['ready'] is False and restored['is_controller'] is False
        assert restored['reconnect']['attempt'] == 0
        after = player.read()
        assert after['path'] == baseline['path'] and after['paused'] is True
        assert after['speed'] == baseline['speed'] and abs(after['position']-baseline['position']) < .5
        player.splay('disconnect')
        wait_for('manual disconnect stops official-server retry lifecycle', lambda: state()['connection'] == 'disconnected' and not state()['reconnect']['pending'])
        (output/'result.json').write_text(json.dumps({'passed': True, 'official_version': '1.7.6',
            'controlled_room_restored': True, 'permissions_reset': True, 'playback_preserved': True}, indent=2), encoding='utf-8')
        print('PASS: unmodified official server restart, actual room, permissions and media preservation:', output)
    finally:
        if processes:
            try:
                player.command('quit')
                time.sleep(.2)
            except OSError:
                pass
        job.close()
        for process in processes:
            process.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
