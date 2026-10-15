"""Two real splay players, real console input and unmodified official server.

Complements interop.py's official-client checks: no Lua/core doubles here.
All files and listeners are isolated from the user's active mpv configuration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time
import uuid

from interop import Job, ROOT, wait_for

parser = argparse.ArgumentParser()
parser.add_argument('--mpv', type=Path, default=ROOT/'.local/mpv/runtime/mpv.exe')
parser.add_argument('--uosc', type=Path, help='Optional uosc script directory; loaded only in isolated test players')
parser.add_argument('--uosc-config', type=Path, help='Optional uosc.conf or config directory; copied before loading')
parser.add_argument('--fonts', type=Path, default=ROOT/'.local/uosc/fonts', help='Fonts copied into each isolated test player')
args = parser.parse_args()
if args.uosc_config and not args.uosc:
    parser.error('--uosc-config requires --uosc')
uosc_config = args.uosc_config
if uosc_config and uosc_config.is_dir():
    uosc_config = uosc_config/'script-opts/uosc.conf'
if uosc_config and not uosc_config.is_file():
    parser.error('--uosc-config must identify an existing uosc.conf or config directory')
uosc_config_hash = hashlib.sha256(uosc_config.read_bytes()).hexdigest() if uosc_config else None
source_controls = None
if uosc_config:
    for line in uosc_config.read_text(encoding='utf-8-sig').splitlines():
        key, separator, value = line.strip().partition('=')
        if separator and key.strip() == 'controls':
            source_controls = value.strip()
uosc_version = None
if args.uosc:
    main = args.uosc/'main.lua' if args.uosc.is_dir() else args.uosc
    if main.is_file():
        match = re.search(r"local uosc_version\s*=\s*'([^']+)'", main.read_text(encoding='utf-8'))
        if match:
            uosc_version = match.group(1)
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
        self.input_config = self.config/'input.conf'
        self.input_config.write_text('ENTER cycle fullscreen\n', encoding='utf-8')
        if uosc_config:
            (self.config/'script-opts').mkdir()
            shutil.copy2(uosc_config, self.config/'script-opts/uosc.conf')
        if args.fonts.is_dir():
            shutil.copytree(args.fonts, self.config/'fonts')
        for path in (ROOT/'build/splay_core.dll', ROOT/'scripts/splay.lua', ROOT/'scripts/splay_overlay.lua'):
            shutil.copy2(path, self.config/'scripts'/path.name)
        self.pipe_name = r'\\.\pipe\splay_full_'+uuid.uuid4().hex
        command = [args.mpv, '--load-scripts=no', '--config-dir='+str(self.config),
            '--script='+str(self.config/'scripts/splay_core.dll'),
            '--script='+str(self.config/'scripts/splay.lua'),
            '--script='+str(self.config/'scripts/splay_overlay.lua'),
            '--input-conf='+str(self.input_config),
            '--input-ipc-server='+self.pipe_name, '--force-window=yes',
            '--geometry=1000x680+50+50', '--pause=yes', '--ao=null',
            '--screenshot-format=png', ROOT/'.local/test-media.mp4']
        if args.uosc:
            command += ['--script='+str(args.uosc)]
        if (self.config/'fonts').is_dir():
            command += ['--osd-fonts-dir='+str(self.config/'fonts')]
        self.process = launch(name, command)
        players.append(self)
        self.pipe = None
        def opened():
            try:
                self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                return True
            except OSError:
                return False
        wait_for(name+' IPC ready', opened)
        wait_for(name+' production overlay initialized', lambda: self.geometry().get('width', 0) > 0)
        if source_controls and source_controls != 'never':
            wait_for(name+' copied uosc layout integrated', lambda: self.geometry().get('integrated'))
            runtime_controls = self.get('options/script-opts')['uosc-controls']
            assert runtime_controls.count('button:splay') == 1, runtime_controls
            preserved = runtime_controls if 'button:splay' in source_controls else runtime_controls.replace(',button:splay', '', 1)
            assert preserved == source_controls, 'the copied layout must retain every original control in order'
        if uosc_config:
            assert hashlib.sha256((self.config/'script-opts/uosc.conf').read_bytes()).hexdigest() == uosc_config_hash

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

    def move(self, x, y):
        self.cmd('mouse', int(x), int(y))
        self.cmd('keypress', 'MOUSE_MOVE')
        time.sleep(.18)

    def click(self, x, y):
        self.move(x, y)
        self.cmd('keydown', 'MBTN_LEFT')
        time.sleep(.06)
        self.cmd('keyup', 'MBTN_LEFT')
        time.sleep(.18)

    def open_popup(self):
        geometry = self.geometry()
        self.move(geometry['width']/2, geometry['height']-15)
        if args.uosc:
            # Place the cursor near the actual control row before dispatching
            # its command, so the production popup has a realistic anchor.
            self.move(max(20, geometry['width']-306), geometry['height']-65)
            # uosc does not publish its individual button rectangles. Exercise
            # its exact configured command, then click production popup rows.
            self.cmd('script-message-to', 'splay_overlay', 'splay-popup')
            self.popup_open_method = 'uosc configured splay-popup command via IPC'
        else:
            def reveal_icon():
                # Fullscreen property changes before Windows finishes resizing
                # the video surface. Recompute coordinates from the current
                # viewport instead of waiting with an obsolete mouse position.
                current = self.geometry()
                self.move(current['width']/2, current['height']-15)
                return self.geometry().get('buttons')
            wait_for(self.name+' standalone icon becomes visible', reveal_icon)
            button = self.geometry()['buttons'][0]
            self.click((button['x1']+button['x2'])/2, (button['y1']+button['y2'])/2)
            self.popup_open_method = 'actual standalone icon mouse click'
        wait_for(self.name+' production compact popup opens', lambda: self.geometry().get('popup_open'))
        assert self.geometry()['rows'][0]['value'] == 'toggle-enabled'

    def click_row(self, value):
        row = next(item for item in self.geometry()['rows'] if item['value'] == value)
        self.click((row['x1']+row['x2'])/2, (row['y1']+row['y2'])/2)

    def open_chat(self):
        if self.get('user-data/mpv/console/open') is True:
            return True
        self.cmd('keypress', 'ENTER')
        time.sleep(.1)
        return self.get('user-data/mpv/console/open') is True

    def type_chat(self, text):
        fullscreen = self.get('fullscreen')
        wait_for(self.name+' real chat prompt opens after connection', self.open_chat)
        assert self.get('fullscreen') == fullscreen, 'eligible Enter must open chat over the user fullscreen binding'
        for character in text:
            self.cmd('keypress', 'SPACE' if character == ' ' else character)
        self.cmd('keypress', 'ENTER')

    def capture(self, name):
        time.sleep(.15)
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
    for player in (a, b):
        assert player.get('user-data/splay')['enabled'] is False
        original_path, original_pause = player.get('path'), player.get('pause')
        fullscreen = player.get('fullscreen')
        player.cmd('keypress', 'ENTER')
        wait_for('disabled Enter retains fullscreen binding', lambda: player.get('fullscreen') != fullscreen)
        assert player.get('user-data/mpv/console/open') is not True
        player.cmd('keypress', 'ENTER')
        wait_for('disabled Enter restores fullscreen', lambda: player.get('fullscreen') == fullscreen)
        player.open_popup()
        assert len(player.geometry()['rows']) <= 2
        if player is a:
            player.capture('real-popup-disabled')
        player.click_row('toggle-enabled')
        wait_for('explicit enable publishes enabled state', lambda: player.get('user-data/splay')['enabled'])
        assert player.geometry().get('popup_open'), 'enabling must keep the compact popup open'
        assert len(player.geometry()['rows']) <= 6
        if player is a:
            player.capture('real-popup-enabled')
        player.click_row('toggle-enabled')
        wait_for('explicit disable publishes disabled state', lambda: not player.get('user-data/splay')['enabled'])
        player.cmd('keypress', 'ESC')
        wait_for('popup closes after Escape', lambda: not player.geometry().get('popup_open'))
        assert player.get('path') == original_path and player.get('pause') == original_pause
    room = 'ui-path-'+uuid.uuid4().hex[:8]
    for player in (a, b):
        player.splay(action='connect', host='127.0.0.1', port=port,
                     username=player.name, room=room, tls='off')
    wait_for('both players connected and eligible for Enter chat', lambda:
             all(player.get('user-data/splay')['connection'] == 'connected' for player in (a, b)))
    a.open_popup()
    a.capture('real-popup-connected')
    a.click_row('chat')
    wait_for('popup chat action closes popup and opens actual chat input',
             lambda: not a.geometry().get('popup_open') and a.get('user-data/mpv/console/open') is True)
    a.cmd('keypress', 'ESC')
    wait_for('popup chat can be cancelled', lambda: a.get('user-data/mpv/console/open') is not True)
    wait_for('Enter opens cancellable real chat prompt', a.open_chat)
    for character in 'cancelled draft':
        a.cmd('keypress', 'SPACE' if character == ' ' else character)
    a.cmd('keypress', 'ESC')
    wait_for('Escape closes chat without sending', lambda: a.get('user-data/mpv/console/open') is not True)
    time.sleep(.2)
    assert a.geometry().get('chat_count') == 0 and b.geometry().get('chat_count') == 0
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
    a.cmd('keypress', 'ESC')
    wait_for('Escape closes the production panel', lambda: a.get('user-data/mpv/console/open') is not True)
    # Refresh a real chat entry immediately before disabling, so clearing the
    # overlay cannot pass merely because the chat display timed out.
    b.type_chat('before disable')
    wait_for('connected peer has chat to clear on disable', lambda: b.geometry().get('chat_count', 0) > 0)
    for player in (a, b):
        assert player.get('user-data/splay')['connection'] == 'connected'
        original_path, original_pause = player.get('path'), player.get('pause')
        player.cmd('script-message-to', 'splay', 'splay-action', 'toggle-enabled')
        wait_for('disabling a connected player disconnects and hides status', lambda:
                 player.get('user-data/splay')['enabled'] is False and
                 player.get('user-data/splay')['connection'] == 'disconnected' and
                 player.geometry().get('status_shown') is False and
                 player.geometry().get('chat_count') == 0 and
                 not player.geometry().get('playback_active'))
        assert player.get('path') == original_path and player.get('pause') == original_pause
        fullscreen = player.get('fullscreen')
        player.cmd('keypress', 'ENTER')
        wait_for('disabling connected chat restores original Enter fullscreen', lambda: player.get('fullscreen') != fullscreen)
        assert player.get('user-data/mpv/console/open') is not True
        player.cmd('keypress', 'ENTER')
        wait_for('restored Enter cycles fullscreen back', lambda: player.get('fullscreen') == fullscreen)
        assert player.get('path') == original_path and player.get('pause') == original_pause
    if uosc_config:
        assert hashlib.sha256(uosc_config.read_bytes()).hexdigest() == uosc_config_hash, 'source uosc configuration must stay unchanged'
    (output/'result.json').write_text(json.dumps(dict(result='passed', mpv=str(args.mpv),
        ui='uosc' if args.uosc else 'native', uosc=str(args.uosc) if args.uosc else None,
        uosc_version=uosc_version,
        uosc_config_source=str(uosc_config) if uosc_config else None,
        uosc_config_sha256=uosc_config_hash,
        uosc_controls=a.get('options/script-opts').get('uosc-controls') if args.uosc else None,
        fonts=str(args.fonts) if args.fonts.is_dir() else None,
        popup_open=a.popup_open_method, popup_rows='actual production row mouse clicks',
        connected_disable='disconnects, hides status, clears chat/activity, preserves path/pause and restores Enter fullscreen',
        server='unmodified Syncplay 1.7.6', peers='two production splay clients',
        chat_input='Enter opens, Enter sends, Escape cancels; disabled Enter cycles fullscreen', artifacts=str(output)), indent=2), encoding='utf-8')
    print('PASS: default off, disabled Enter fallback, enable preserves media, Enter chat, Escape cancel, actor status, room clear, history and Shift+s; '+str(output), flush=True)
finally:
    job.close()
    for process in processes:
        process.wait(timeout=10)
    for player in players:
        if player.pipe:
            player.pipe.close()
    for log in logs:
        log.close()
