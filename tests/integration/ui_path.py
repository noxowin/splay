"""Two real splay players, real console input and unmodified official server.

Complements interop.py's official-client checks: no Lua/core doubles here.
All files and listeners are isolated from the user's active mpv configuration.
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

parser = argparse.ArgumentParser()
parser.add_argument('--mpv', type=Path, default=ROOT/'.local/mpv/runtime/mpv.exe')
args = parser.parse_args()
output = ROOT/'.local/ui-path'/('run-'+uuid.uuid4().hex[:8])
output.mkdir(parents=True)
job, processes, logs, players = Job(), [], [], []
env = dict(os.environ, APPDATA=str(output/'appdata'), PYTHONUTF8='1')
Path(env['APPDATA']).mkdir()


def launch(name, command):
    log = (output/(name+'.log')).open('wb')
    logs.append(log)
    process = subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env,
                               stdout=log, stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    job.assign(process)
    processes.append(process)
    return process


class Player:
    def __init__(self, name):
        self.name, self.serial = name, 0
        self.config = output/name
        (self.config/'scripts').mkdir(parents=True)
        for path in (ROOT/'build/splay_core.dll', ROOT/'scripts/splay.lua', ROOT/'scripts/splay_overlay.lua'):
            shutil.copy2(path, self.config/'scripts'/path.name)
        self.pipe_name = r'\\.\pipe\splay_full_'+uuid.uuid4().hex
        self.process = launch(name, [args.mpv, '--config-dir='+str(self.config),
            '--input-ipc-server='+self.pipe_name, '--force-window=yes',
            '--geometry=1000x680+50+50', '--pause=yes', '--ao=null',
            '--screenshot-format=png', ROOT/'.local/test-media.mp4'])
        players.append(self)
        self.pipe = None
        def opened():
            try:
                self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                return True
            except OSError:
                return False
        wait_for(name+' IPC ready', opened)
        wait_for(name+' production overlay initialized', lambda: self.get('user-data/splay-overlay'))

    def cmd(self, *command):
        self.serial += 1
        self.pipe.write((json.dumps(dict(command=command, request_id=self.serial))+'\n').encode())
        while True:
            line = self.pipe.readline()
            assert line, 'player IPC closed'
            reply = json.loads(line)
            if reply.get('request_id') == self.serial:
                assert reply['error'] == 'success', reply
                return reply.get('data')

    def get(self, name):
        try:
            return self.cmd('get_property', name)
        except AssertionError:
            return None

    def splay(self, **command):
        self.cmd('script-message-to', 'splay', 'splay-command', json.dumps(command))

    def geometry(self):
        return self.get('user-data/splay-overlay') or {}

    def open_chat(self):
        self.cmd('script-message-to', 'splay', 'splay-chat')
        time.sleep(.1)
        return self.get('user-data/mpv/console/open') is True

    def type_chat(self, text):
        wait_for(self.name+' real chat prompt opens after connection', self.open_chat)
        for character in text:
            self.cmd('keypress', 'SPACE' if character == ' ' else character)
        self.cmd('keypress', 'ENTER')

    def capture(self, name):
        self.cmd('screenshot-to-file', str(output/(name+'.png')), 'window')


try:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    launch('server', [ROOT/'.venv/Scripts/python.exe', ROOT/'.local/upstream/syncplay-1.7.6/syncplayServer.py',
                     '--port', port, '--ipv4-only', '--interface-ipv4', '127.0.0.1', '--salt', 'ui-path-fixture'])
    def listening():
        with socket.socket() as client:
            return client.connect_ex(('127.0.0.1', port)) == 0
    wait_for('unmodified official server listening', listening)
    a, b = Player('splay-A'), Player('splay-B')
    room = 'ui-path-'+uuid.uuid4().hex[:8]
    for player in (a, b):
        player.splay(action='connect', host='127.0.0.1', port=port,
                     username=player.name, room=room, tls='off')
    a.type_chat('中文 hello 😀')
    wait_for('real console -> UI -> DLL -> server -> both overlays',
             lambda: a.geometry().get('chat_count') == 1 and b.geometry().get('chat_count') == 1)
    b.type_chat('reply 中文')
    wait_for('reverse real console chat returns through both production UIs',
             lambda: a.geometry().get('chat_count') == 2 and b.geometry().get('chat_count') == 2)
    for player in (a, b):
        player.splay(action='ready', ready=True)
    time.sleep(1)
    a.cmd('set_property', 'pause', False)
    wait_for('playback activity passes through real UI and overlay',
             lambda: a.geometry().get('playback_active') and b.geometry().get('playback_active'))
    b.capture('real-chat-ready-playback')
    original = a.get('path')
    a.splay(action='room', room=room+'-other')
    wait_for('changing room clears production overlay chat and activity',
             lambda: a.geometry().get('chat_count') == 0 and not a.geometry().get('playback_active'))
    assert a.get('path') == original
    for player in (a, b):
        history = json.loads((player.config/'splay-history.json').read_text(encoding='utf-8'))
        assert history['last']['host'] == '127.0.0.1' and history['profiles']
        assert all(set(profile) == {'host', 'port', 'username', 'room', 'tls'} for profile in history['profiles'])
    a.cmd('keypress', 'Shift+s')
    wait_for('default Shift+s opens actual production panel', lambda: a.get('user-data/mpv/console/open') is True)
    a.capture('real-shift-s-panel')
    (output/'result.json').write_text(json.dumps(dict(result='passed', mpv=str(args.mpv),
        server='unmodified Syncplay 1.7.6', peers='two production splay clients',
        chat_input='mpv keypress into real mp.input console', artifacts=str(output)), indent=2), encoding='utf-8')
    print('PASS: three runtime files auto-load, chat, actor status, room clear, history and Shift+s; '+str(output), flush=True)
finally:
    job.close()
    for process in processes:
        process.wait(timeout=10)
    for player in players:
        if player.pipe:
            player.pipe.close()
    for log in logs:
        log.close()
