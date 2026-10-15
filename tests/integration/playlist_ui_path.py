"""Installed four-runtime playlist UI, two local media files, official server.

Runs isolated native and optional real-uosc players. Uses the same production
actions as their menus; native and uosc menus themselves also open in real mpv.
No user config, mocked server, plugin double, or global mpv queue replacement.
"""
import argparse
import json
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
    parser.add_argument('--mpv', type=Path, default=ROOT/'.local/mpv/runtime/mpv.exe')
    parser.add_argument('--python', type=Path, default=ROOT/'.venv/Scripts/python.exe')
    parser.add_argument('--upstream', type=Path, default=ROOT/'.local/upstream/syncplay-1.7.6')
    parser.add_argument('--plugin', type=Path, default=ROOT/'build/splay_core.dll')
    parser.add_argument('--media', type=Path, default=ROOT/'.local/test-media.mp4')
    parser.add_argument('--uosc', type=Path, default=ROOT/'.local/uosc/scripts/uosc')
    parser.add_argument('--native-only', action='store_true')
    args = parser.parse_args()
    output = ROOT/'.local/playlist-ui'/('run-'+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    fixtures = output/'media'
    fixtures.mkdir()
    first, second = fixtures/'first-本机.mp4', fixtures/'second-本机.mp4'
    shutil.copy2(args.media, first)
    shutil.copy2(args.media, second)
    env = dict(os.environ, APPDATA=str(output/'appdata'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    Path(env['APPDATA']).mkdir()
    job, processes, logs, players = Job(), [], [], []

    def launch(name, command, cwd=ROOT):
        log = (output/(name+'.log')).open('wb')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=cwd, env=env,
                                   stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        job.assign(process)
        processes.append(process)
        return process

    class Player:
        def __init__(self, name, media, uosc=False):
            self.name, self.serial, self.pipe = name, 0, None
            self.config = output/name
            scripts = self.config/'scripts'
            scripts.mkdir(parents=True)
            for source in (args.plugin, ROOT/'scripts/splay.lua', ROOT/'scripts/splay_overlay.lua', ROOT/'scripts/splay_playlist.lua'):
                shutil.copy2(source, scripts/source.name)
            self.pipe_name = r'\\.\pipe\splay_playlist_'+uuid.uuid4().hex
            command = [args.mpv, '--config-dir='+str(self.config), '--load-scripts=yes',
                       '--input-ipc-server='+self.pipe_name, '--pause=yes', '--ao=null', '--idle=yes',
                       '--force-window=yes', '--geometry=820x600+1080+50', '--keep-open=no',
                       '--screenshot-format=png', media]
            command += ['--script='+str(ROOT/'tests/integration/playlist_observer.lua')]
            if uosc:
                command += ['--script='+str(args.uosc)]
                fonts = ROOT/'.local/uosc/fonts'
                if fonts.is_dir():
                    command += ['--osd-fonts-dir='+str(fonts)]
            self.process = launch(name, command)
            players.append(self)
            def opened():
                try:
                    self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                    return True
                except OSError:
                    return False
            wait_for(name+' real mpv IPC ready', opened)
            wait_for(name+' installed playlist runtime initialized', lambda: self.get('user-data/splay-playlist') is not None)
            wait_for(name+' fixture loaded', lambda: (self.get('duration') or 0) > 1)
            assert self.get('path') == str(media)
            assert self.ui()['follow'] is False

        def cmd(self, *command):
            self.serial += 1
            self.pipe.write((json.dumps(dict(command=command, request_id=self.serial))+'\n').encode())
            while True:
                line = self.pipe.readline()
                assert line, self.name+' IPC closed'
                reply = json.loads(line)
                if reply.get('request_id') == self.serial:
                    assert reply['error'] == 'success', reply
                    return reply.get('data')

        def get(self, name):
            self.serial += 1
            self.pipe.write((json.dumps(dict(command=['get_property', name], request_id=self.serial))+'\n').encode())
            while True:
                reply = json.loads(self.pipe.readline())
                if reply.get('request_id') == self.serial:
                    return reply.get('data') if reply['error'] == 'success' else None

        def splay(self, action, **values):
            self.cmd('script-message-to', 'splay', 'splay-command', json.dumps(dict(action=action, **values)))

        def act(self, action):
            self.cmd('script-message-to', 'splay_playlist', 'splay-playlist-action', action)

        def ui(self):
            return self.get('user-data/splay-playlist') or {}

        def state(self):
            return self.get('user-data/splay-state') or {}

        def open(self, mode):
            self.cmd('script-message-to', 'splay_playlist', 'splay-playlist-open', mode)

        def select(self, zero_index):
            self.act('item:{}:{}'.format(self.ui()['generation'], zero_index+1))
            wait_for(self.name+' item menu opens', lambda: self.ui().get('menu') == 'item')
            self.act('select')

        def close_console(self):
            self.cmd('keypress', 'ESC')

    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        launch('server', [args.python, args.upstream/'syncplayServer.py', '--port', port,
                         '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'playlist-ui-fixture'], args.upstream)
        def listening():
            with socket.socket() as client:
                return client.connect_ex(('127.0.0.1', port)) == 0
        wait_for('unmodified Syncplay 1.7.6 server listens', listening)
        leader = Player('native', first)
        follower = Player('uosc' if not args.native_only else 'native-follower', second, not args.native_only)
        room = 'playlist-ui-'+uuid.uuid4().hex[:8]
        leader.splay('connect', host='127.0.0.1', port=port, room=room, username='leader', tls='off')
        wait_for('leader connects through main enabled gate', lambda: leader.get('user-data/splay').get('connection') == 'connected')
        leader.splay('playlist-set', files=[first.name, second.name])
        wait_for('official server echoes initial list', lambda: leader.ui().get('count') == 2)
        leader.splay('playlist-index', index=0)
        wait_for('official server confirms initial item', lambda: leader.ui().get('index') == 0)
        follower.splay('connect', host='127.0.0.1', port=port, room=room, username='follower', tls='off')
        wait_for('joining follower receives existing shared list', lambda: follower.ui().get('count') == 2 and follower.ui().get('index') == 0)
        assert follower.get('path') == str(second), 'first incoming shared list replaced caller media'
        assert leader.get('path') == str(first) and not follower.ui()['follow']
        print('PASS: installed native DLL + three Lua files preserve both callers on join', flush=True)

        leader.open('native')
        wait_for('real native playlist selector opens', lambda: leader.get('user-data/mpv/console/open') is True)
        time.sleep(.2)
        leader.cmd('screenshot-to-file', str(output/'native-playlist.png'), 'window')
        leader.cmd('keypress', 'DOWN')
        time.sleep(.12)
        leader.cmd('keypress', 'DOWN')
        time.sleep(.12)
        leader.cmd('screenshot-to-file', str(output/'native-browser-choice.png'), 'window')
        leader.cmd('keypress', 'ENTER')
        wait_for('native keyboard selection opens playlist browser', lambda: leader.ui().get('menu') == 'list')
        leader.close_console()
        if not args.native_only:
            follower.open('uosc')
            wait_for('real optional uosc playlist menu opens', lambda: follower.get('user-data/uosc/menu/type') == 'splay-playlist')
            time.sleep(.2)
            follower.cmd('screenshot-to-file', str(output/'uosc-playlist.png'), 'window')
            follower.cmd('keypress', 'DOWN')
            time.sleep(.08)
            follower.cmd('keypress', 'DOWN')
            time.sleep(.08)
            follower.cmd('keypress', 'ENTER')
            wait_for('uosc activation opens playlist browser', lambda: follower.ui().get('menu') == 'list')
            time.sleep(.2)
            assert follower.get('user-data/uosc/menu/type') == 'splay-playlist', 'stale menu-close callback closed the next page'
            follower.cmd('keypress', 'DOWN')
            time.sleep(.08)
            follower.cmd('keypress', 'DOWN')
            time.sleep(.08)
            follower.cmd('keypress', 'ENTER')
            wait_for('uosc activation opens item actions', lambda: follower.ui().get('menu') == 'item')
            time.sleep(.2)
            assert follower.get('user-data/uosc/menu/type') == 'splay-playlist'
            follower.cmd('script-message-to', 'uosc', 'close-menu', 'splay-playlist')

        # Local queue and server list are independent. Explicit import strips
        # directories and skips a private URL without opening it.
        private = 'https://private.invalid/video?token=LOCAL_ONLY_SECRET'
        leader.cmd('loadfile', str(second), 'append')
        leader.cmd('loadfile', private, 'append')
        before_queue = leader.get('playlist')
        leader.act('import-preview')
        time.sleep(.2)
        assert leader.ui()['count'] == 2, 'import preview shared the queue before confirmation'
        leader.act('import')
        wait_for('explicit import shares local basenames only', lambda: leader.ui().get('count') == 4 and follower.ui().get('count') == 4)
        assert leader.get('playlist') == before_queue, 'server playlist import rewrote mpv queue'
        leader.close_console()
        leader.splay('playlist-set', files=[first.name, second.name])
        wait_for('restore two-item server list', lambda: follower.ui().get('count') == 2)

        follower.act('follow')
        wait_for('explicit follow opt-in loads room current local fixture', lambda: follower.get('path') == str(first))
        follower.close_console()
        leader.select(1)
        wait_for('explicit UI selection loads leader after server echo', lambda: leader.ui().get('index') == 1 and leader.get('path') == str(second))
        wait_for('opted-in follower follows server item without queue replacement', lambda: follower.ui().get('index') == 1 and follower.get('path') == str(second))
        follower.act('follow')
        follower.close_console()
        leader.select(0)
        wait_for('leader selects first fixture for EOF check', lambda: leader.ui().get('index') == 0 and leader.get('path') == str(first))
        wait_for('follower sees new index while opted out', lambda: follower.ui().get('index') == 0)
        assert follower.get('path') == str(second), 'follow OFF failed to preserve local fixture'

        leader.act('follow')
        leader.close_console()
        duration = leader.get('duration')
        leader.cmd('set_property', 'pause', False)
        leader.cmd('seek', max(0, duration-.12), 'absolute+exact')
        try:
            wait_for('real EOF advances shared room once and loads next fixture',
                     lambda: leader.ui().get('index') == 1 and leader.get('path') == str(second), seconds=25)
        except AssertionError:
            diagnostic = {key: leader.get(key) for key in ('path', 'pause', 'time-pos', 'eof-reached',
                          'idle-active', 'user-data/splay-playlist', 'user-data/splay-playlist-observations')}
            (output/'eof-diagnostic.json').write_text(json.dumps(diagnostic, ensure_ascii=False, indent=2), encoding='utf-8')
            raise
        wait_for('EOF selection reaches opted-out follower without local load', lambda: follower.ui().get('index') == 1)
        leader.cmd('set_property', 'pause', True)
        assert follower.get('path') == str(second)
        print('PASS: explicit follow, selecting, opt-out and actual EOF next media through official server', flush=True)

        leader.act('follow')
        leader.close_console()
        leader.splay('playlist-set', files=['D:/never-load-a-remote-path.mp4'])
        wait_for('server accepts opaque remote path reference', lambda: leader.ui().get('count') == 1)
        leader.splay('playlist-index', index=0)
        wait_for('server confirms opaque item', lambda: leader.ui().get('index') == 0)
        before_path = leader.get('path')
        leader.act('play-current')
        time.sleep(.3)
        assert leader.get('path') == before_path
        previous_generation = leader.ui()['generation']
        leader.splay('playlist-set', files=['https://unapproved.invalid/media?token=REMOTE_SECRET'])
        wait_for('server echoes unapproved HTTP reference', lambda: leader.ui().get('generation', 0) > previous_generation)
        leader.splay('playlist-index', index=0)
        leader.act('play-current')
        wait_for('unapproved HTTP reference opens single-item consent menu', lambda: leader.ui().get('menu') == 'url')
        assert leader.get('path') == before_path
        leader.close_console()

        for player in players:
            assert set(path.name for path in (player.config/'scripts').iterdir()) == {
                'splay_core.dll', 'splay.lua', 'splay_overlay.lua', 'splay_playlist.lua'}
        result = {'server': 'unmodified Syncplay 1.7.6', 'runtimes': 4,
                  'interfaces': ['native'] + ([] if args.native_only else ['uosc']),
                  'fixtures': [first.name, second.name], 'passed': True}
        (output/'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('PLAYLIST_UI_PATH_PASSED '+str(output), flush=True)
    finally:
        for player in players:
            if player.pipe:
                player.pipe.close()
        job.close()
        for process in processes:
            process.wait(timeout=5)
        for log in logs:
            log.close()
        for path in output.glob('*.log'):
            text = path.read_text(encoding='utf-8', errors='replace')
            assert 'Lua error' not in text and 'stack traceback' not in text, str(path)+'\n'+text


if __name__ == '__main__':
    main()
