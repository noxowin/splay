"""Real mpv windows and mpv mouse input events; protocol/core are mocked."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
parser.add_argument('--uosc', type=Path, default=ROOT / '.local/uosc/scripts/uosc')
parser.add_argument('--output', type=Path, default=ROOT / '.local/v2-overlay')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
fixture = args.output / 'fixture'
fixture.mkdir(exist_ok=True)
shutil.copyfile(ROOT / 'tests/ui/overlay_host.lua', fixture / 'splay.lua')


class Player:
    def __init__(self, mode):
        self.mode = mode
        self.log = (args.output / (mode + '.log')).open('wb')
        self.pipe_name = r'\\.\pipe\splay_overlay_' + str(time.time_ns())
        command = [str(args.mpv), '--no-config', '--ao=null', '--pause=yes',
                   '--force-window=yes', '--geometry=1100x700+50+50',
                   '--input-ipc-server=' + self.pipe_name, '--screenshot-format=png',
                   '--osd-fonts-dir=' + str(ROOT / '.local/uosc/fonts'),
                   '--script=' + str(fixture / 'splay.lua'),
                   '--script=' + str(ROOT / 'scripts/splay_overlay.lua'),
                   '--script-opts=splay-overlay_chat_ttl=3',
                   str(ROOT / '.local/test-media.mp4')]
        if mode == 'uosc': command += ['--script=' + str(args.uosc)]
        self.process = subprocess.Popen(command, cwd=ROOT, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 12
        while True:
            try:
                self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                break
            except OSError:
                assert time.monotonic() < deadline, 'IPC pipe did not open'
                time.sleep(.05)
        self.serial = 0
        time.sleep(.5)
        time.sleep(.2)

    def cmd(self, *command):
        self.serial += 1
        self.pipe.write((json.dumps({'command': command, 'request_id': self.serial}) + '\n').encode())
        while True:
            line = self.pipe.readline()
            assert line, 'mpv closed its pipe'
            reply = json.loads(line)
            if reply.get('request_id') == self.serial:
                assert reply.get('error') == 'success', reply
                return reply.get('data')

    def get(self, key, default=None):
        try: return self.cmd('get_property', key)
        except AssertionError: return default

    def state(self, **changes):
        state = {'schema': 1, 'connection': 'connected', 'encrypted': True,
                 'username': '本机用户', 'room': '周末电影', 'ready': False,
                 'chat_supported': True, 'chat_max_length': 500,
                 'members': [{'username': '小明', 'room': '周末电影', 'ready': True},
                             {'username': '本机用户', 'room': '周末电影', 'ready': False},
                             {'username': '远方的朋友', 'room': '周末电影'}]}
        state.update(changes)
        self.cmd('script-message-to', 'splay_overlay', 'splay-state', json.dumps(state, ensure_ascii=False))
        time.sleep(.12)

    def event(self, **event):
        event.update(schema=1)
        self.cmd('script-message-to', 'splay_overlay', 'splay-event', json.dumps(event, ensure_ascii=False))
        time.sleep(.08)

    def geometry(self): return self.get('user-data/splay-overlay', {})

    def move(self, x, y):
        self.cmd('mouse', int(x), int(y))
        self.cmd('keypress', 'MOUSE_MOVE')
        time.sleep(.18)

    def click(self, x, y):
        self.move(x, y)
        self.cmd('keydown', 'MBTN_LEFT')
        time.sleep(.06)
        self.cmd('keyup', 'MBTN_LEFT')
        time.sleep(.2)

    def capture(self, label):
        self.cmd('screenshot-to-file', str(args.output / (self.mode + '-' + label + '.png')), 'window')

    def show_buttons(self):
        g = self.geometry()
        self.move(g['width'] / 2, g['height'] - 15)
        time.sleep(.15)
        g = self.geometry()
        assert g['visible'] and len(g['buttons']) == 3, g
        return g

    def click_button(self, index):
        r = self.show_buttons()['buttons'][index]
        self.click((r['x1']+r['x2'])/2, (r['y1']+r['y2'])/2)

    def action(self): return self.get('user-data/overlay-test/action', {})

    def close_menu(self):
        if self.mode == 'uosc': self.cmd('script-message-to', 'uosc', 'close-menu', 'splay')
        self.cmd('keypress', 'ESC')
        time.sleep(.25)

    def close(self):
        try: self.cmd('quit')
        except (AssertionError, OSError): pass
        self.process.wait(timeout=8)
        self.pipe.close()
        self.log.close()
        log = (args.output / (self.mode + '.log')).read_text(encoding='utf-8', errors='replace')
        assert self.process.returncode == 0 and 'Lua error' not in log and 'stack traceback' not in log, log


for mode in ('native', 'uosc'):
    player = Player(mode)
    try:
        assert player.action()['kind'] == 'handshake'
        player.state()
        player.event(type='playback', id='p1', username='小明', paused=True, position=3661)
        player.event(type='chat', id='c1', username='小明', text='大家晚上好，准备好就一起开始吧！ 😊 👨‍👩‍👧‍👦 👍🏽 🇨🇳')
        player.event(type='chat', id='c2', username='朋友', text=r'ASS 100% {\pos(999,999)\c&H0000FF&}原样显示 \N 不换行')
        player.event(type='chat', id='c2', username='朋友', text='重复事件应被忽略')
        assert player.geometry()['chat_count'] == 2
        player.show_buttons()
        player.capture('status-chat-buttons')
        # Mouse events pass through real mpv input routing and scoped sections.
        player.click_button(1)
        assert player.action()['kind'] == 'ready' and player.action()['value'] is True, player.action()
        player.click_button(2)
        assert player.action()['kind'] == 'chat'
        assert not player.geometry()['visible'], 'chat console must suppress buttons'
        player.capture('chat-input')
        player.close_menu()
        player.click_button(0)
        assert player.action() == {'count': 4, 'kind': 'panel', 'value': mode}, player.action()
        assert not player.geometry()['visible'], 'panel menu must suppress buttons'
        player.capture('panel')
        player.close_menu()
        # Native/user left-click binding still fires outside the row and while
        # the overlay is hidden, even when uosc is also installed.
        player.cmd('define-section', 'overlay-test-left', 'MBTN_LEFT cycle pause', 'force')
        player.cmd('enable-section', 'overlay-test-left')
        g = player.show_buttons()
        player.move(40, 80)
        time.sleep(1.5)
        assert not player.geometry()['visible']
        player.cmd('set_property', 'pause', True)
        player.click(40, 80)
        assert player.get('pause') is False, 'hidden overlay swallowed normal left-click'
        player.cmd('set_property', 'pause', True)
        player.show_buttons()
        player.click(40, 80)
        assert player.get('pause') is False, 'visible overlay swallowed outside left-click'
        player.cmd('disable-section', 'overlay-test-left')
        player.cmd('set_property', 'pause', True)
        # Timeline remains seekable with actual native/uosc pointer handling.
        player.show_buttons()
        g = player.geometry()
        player.cmd('set_property','time-pos',0)
        timeline_x=g['width']*(.72 if mode=='uosc' else .55)
        player.click(timeline_x, g['height']-(16 if mode=='uosc' else 15))
        if mode=='native' and player.get('time-pos')<=90:
            for offset in (58,56,54,52,50,48,46,44,42,40,38,36,34,32,30,28,26,24,22,20,18,16,14,12,10,8,6,4,2):
                player.click(timeline_x,g['height']-offset)
                if player.get('time-pos')>90:
                    print('Native timeline found at bottom offset',offset,flush=True)
                    break
        assert player.action()['count'] == 4, 'timeline click triggered splay'
        player.capture('timeline-click')
        assert player.get('time-pos') > 90, ('timeline did not seek through actual native/uosc input',player.get('time-pos'),player.get('mouse-pos'))
        # TTL, disconnect and room changes are separate state transitions.
        time.sleep(3.2)
        assert player.geometry()['chat_count'] == 0
        player.event(type='chat', id='c3', username='朋友', text='切房间前的消息')
        player.event(type='chat', id='nul', username='朋友', text='前半\x00后半 \\u0000 100%')
        player.capture('nul-literal')
        player.state(room='另一个房间', members=[])
        assert player.geometry()['chat_count'] == 0 and not player.geometry()['playback_active']
        player.event(type='chat', id='c4', username='朋友', text='断开连接前的消息')
        player.state(connection='disconnected', room='另一个房间', members=[])
        assert player.geometry()['chat_count'] == 0
        player.event(type='chat', id='c5', username='朋友', text='断开后应忽略')
        assert player.geometry()['chat_count'] == 0
        player.show_buttons()
        player.capture('disconnected')
        count = player.action()['count']
        player.click_button(1)
        player.click_button(2)
        assert player.action()['count'] == count, 'disconnected actions must be disabled'
        player.state(ready=True,members=[{'username':'小明','room':'周末电影','ready':True},
                                       {'username':'本机用户','room':'周末电影','ready':True}])
        player.capture('all-ready')
        player.cmd('set_property','window-scale',1.5)
        time.sleep(.4)
        g=player.show_buttons()
        for r in g['buttons']:
            assert 0<=r['x1']<r['x2']<=g['width'] and 0<=r['y1']<r['y2']<=g['height'], g
        player.capture('small-window')
        player.cmd('script-message-to','splay_overlay','overlay-toggle-status')
        time.sleep(.1)
        assert player.geometry()['status_enabled'] is False
        player.cmd('script-message-to','splay_overlay','overlay-toggle-buttons')
        time.sleep(.1)
        assert not player.geometry()['visible']
        player.capture('hidden')
        print(mode + ': real pointer panel/ready/chat; scoped/hidden clicks; menus; TTL; room/disconnect; toggles passed')
    finally:
        player.close()
print('Offline overlay review passed. Mocked host; no network/protocol claim.')
