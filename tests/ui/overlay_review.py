"""Real mpv windows and mpv mouse input events; protocol/core are mocked."""
import argparse
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tests/integration'))
from interop import Job

# Closing the parent also closes this Windows job, including on interruption.
job = Job()
parser = argparse.ArgumentParser()
parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
parser.add_argument('--uosc', type=Path, default=ROOT / '.local/uosc/scripts/uosc')
parser.add_argument('--mode', choices=('native','uosc','all'), default='all')
parser.add_argument('--output', type=Path, default=ROOT / '.local/v3-overlay')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
fixture = args.output / 'fixture'
fixture.mkdir(exist_ok=True)
(fixture / 'script-opts').mkdir(exist_ok=True)
shutil.copyfile(ROOT / 'tests/ui/fixtures/uosc-layout.conf', fixture / 'script-opts/uosc.conf')
shutil.copyfile(ROOT / 'tests/ui/overlay_host.lua', fixture / 'splay.lua')


class Player:
    def __init__(self, mode):
        self.mode = mode
        self.log = (args.output / (mode + '.log')).open('wb')
        self.pipe_name = r'\\.\pipe\splay_overlay_' + str(time.time_ns())
        command = [str(args.mpv), '--load-scripts=no', '--config-dir=' + str(fixture), '--ao=null', '--pause=yes',
                   '--force-window=yes', '--geometry=1100x700+50+50',
                   '--input-ipc-server=' + self.pipe_name, '--screenshot-format=png',
                   '--osd-fonts-dir=' + str(ROOT / '.local/uosc/fonts'),
                   '--script=' + str(fixture / 'splay.lua'),
                   '--script=' + str(ROOT / 'scripts/splay_overlay.lua'),
                   '--script-opts=splay-overlay_chat_ttl=3,overlay-test-keep=untouched',
                   str(ROOT / '.local/test-media.mp4')]
        if mode == 'uosc': command += ['--script=' + str(args.uosc)]
        self.process = subprocess.Popen(command, cwd=ROOT, stdout=self.log, stderr=subprocess.STDOUT)
        job.assign(self.process)
        deadline = time.monotonic() + 12
        while True:
            try:
                self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                break
            except OSError:
                assert time.monotonic() < deadline, 'IPC pipe did not open'
                time.sleep(.05)
        self.serial = 0
        self.cmd('set_property', 'user-data/overlay-test/mode', mode)
        time.sleep(.5)
        time.sleep(.2)
        deadline=time.monotonic()+10
        while not self.geometry().get('width'):
            assert time.monotonic()<deadline, self.geometry()
            time.sleep(.1)

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
        state = {'schema': 1, 'enabled': True, 'connection': 'connected', 'encrypted': True,
                 'username': '本机用户', 'room': '周末电影', 'ready': False,
                 'chat_supported': True, 'chat_max_length': 500,
                 'members': [{'username': '小明', 'room': '周末电影', 'ready': True},
                             {'username': '本机用户', 'room': '周末电影', 'ready': False},
                             {'username': '远方的朋友', 'room': '周末电影'}]}
        state.update(changes)
        self.cmd('script-message-to', 'splay', 'fixture-test-state', json.dumps(state, ensure_ascii=False))
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
        if self.mode == 'native':
            assert g['visible'] and len(g['buttons']) == 1, g
        else:
            assert g['integrated'] and not g['buttons'], g
        return g

    def open_popup(self):
        g=self.show_buttons()
        if self.mode=='native':
            r=g['buttons'][0]
            self.click((r['x1']+r['x2'])/2,(r['y1']+r['y2'])/2)
        else:
            # Actual fixture layout: after forward/space, before danmaku. This
            # coordinate is calibrated against the saved real-window capture.
            self.click(g['width']-306, g['height']-60)
        assert self.geometry()['popup_open'], self.geometry()
        return self.geometry()

    def click_row(self,index):
        r=self.geometry()['rows'][index]
        self.click((r['x1']+r['x2'])/2,(r['y1']+r['y2'])/2)

    def action(self): return self.get('user-data/overlay-test/action', {})

    def close_menu(self):
        if self.mode == 'uosc': self.cmd('script-message-to', 'uosc', 'close-menu', 'splay')
        self.cmd('keypress', 'ESC')
        time.sleep(.25)

    def resize(self,width,height):
        user32=ctypes.WinDLL('user32',use_last_error=True)
        handles=[]
        callback_type=ctypes.WINFUNCTYPE(wintypes.BOOL,wintypes.HWND,wintypes.LPARAM)
        def find(hwnd,lparam):
            pid=wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd,ctypes.byref(pid))
            classname=ctypes.create_unicode_buffer(128)
            user32.GetClassNameW(hwnd,classname,128)
            if pid.value==self.process.pid and classname.value=='mpv' and user32.IsWindowVisible(hwnd): handles.append(hwnd)
            return True
        callback=callback_type(find)
        assert user32.EnumWindows(callback,0) and handles
        assert user32.MoveWindow(handles[0],50,50,width,height,True)
        time.sleep(.6)

    def close(self):
        try: self.cmd('quit')
        except (AssertionError, OSError): pass
        self.process.wait(timeout=8)
        self.pipe.close()
        self.log.close()
        log = (args.output / (self.mode + '.log')).read_text(encoding='utf-8', errors='replace')
        assert self.process.returncode == 0 and 'Lua error' not in log and 'stack traceback' not in log, log


for mode in (('native','uosc') if args.mode=='all' else (args.mode,)):
    player=Player(mode)
    try:
        assert player.action()['kind']=='handshake'
        g=player.geometry()
        assert g['enabled'] is False and g['status_shown'] is False
        player.event(type='chat',id='disabled',username='朋友',text='关闭时不应出现')
        assert player.geometry()['chat_count']==0
        player.show_buttons()
        player.capture('default-off')
        player.move(g['width']*.7,g['height']-16)
        player.cmd('script-message-to','splay_overlay','splay-popup')
        time.sleep(.2)
        anchored=player.geometry()
        assert anchored['popup_open']
        assert anchored['popup']['y2']<anchored['height']-80, anchored
        player.capture('popup-from-timeline')
        player.cmd('keypress','ESC'); time.sleep(.2)
        player.open_popup()
        assert player.geometry()['rows'][0]['value']=='toggle-enabled'
        player.capture('popup-off')
        player.click_row(0)
        assert player.geometry()['popup_open'] and player.geometry()['enabled']
        player.cmd('keypress','ESC')
        time.sleep(.2)
        assert not player.geometry()['popup_open']
        player.state()
        player.event(type='playback',id='p1',username='小明',paused=True,position=3661)
        player.event(type='chat',id='c1',username='小明',text='大家晚上好！ 😊 👨‍👩‍👧‍👦 👍🏽 🇨🇳')
        player.event(type='chat',id='c2',username='朋友',text=r'ASS 100% {\pos(999,999)\c&H0000FF&}原样显示 \N 不换行')
        player.event(type='chat',id='c2',username='朋友',text='重复事件应忽略')
        assert player.geometry()['chat_count']==2
        player.show_buttons()
        player.capture('enabled-status-chat')
        player.open_popup()
        player.capture('popup-enabled')
        player.click_row(3)
        assert player.action()['value']=='ready' and not player.geometry()['popup_open']
        player.open_popup(); player.click_row(4)
        assert player.action()['value']=='chat' and not player.geometry()['popup_open']
        player.capture('chat-input'); player.close_menu()
        player.open_popup(); player.click_row(1)
        assert player.action()['value']=='settings' and not player.geometry()['popup_open']
        player.capture('settings'); player.close_menu()
        # Foreign menus dismiss the popup and retain their normal pointer scope.
        player.open_popup()
        if mode=='uosc':
            player.cmd('script-message-to','uosc','open-menu',json.dumps({'type':'foreign','title':'其他菜单','items':[{'title':'原有菜单','selectable':False}]}))
        else:
            player.cmd('script-message-to','splay','fixture-foreign-menu')
        time.sleep(.25)
        assert not player.geometry()['popup_open']
        player.close_menu()
        # An outside click dismisses and runs the original user binding once.
        player.cmd('define-section','overlay-test-left','MBTN_LEFT cycle pause','force')
        player.cmd('enable-section','overlay-test-left')
        player.open_popup()
        player.cmd('set_property','pause',True)
        player.click(40,80)
        assert not player.geometry()['popup_open'] and player.get('pause') is False
        player.cmd('set_property','pause',True)
        player.click(40,80)
        assert player.get('pause') is False
        player.cmd('disable-section','overlay-test-left')
        player.cmd('set_property','pause',True)
        # Timeline still seeks, including a click that dismisses the popup.
        player.open_popup()
        g=player.geometry()
        player.cmd('set_property','time-pos',0)
        player.click(g['width']*.72,g['height']-16)
        if mode=='native' and player.get('time-pos')<=90:
            for offset in range(58,1,-2):
                player.click(g['width']*.55,g['height']-offset)
                if player.get('time-pos')>90: break
        assert not player.geometry()['popup_open']
        assert player.get('time-pos')>90, player.get('time-pos')
        player.capture('timeline-click')
        time.sleep(3.2)
        assert player.geometry()['chat_count']==0
        player.event(type='chat',id='nul',username='朋友',text='前半\x00后半 \\u0000 100%')
        player.capture('nul-literal')
        player.state(room='另一个房间',members=[])
        assert player.geometry()['chat_count']==0 and not player.geometry()['playback_active']
        player.state(connection='disconnected',members=[])
        player.event(type='chat',id='disconnected',username='朋友',text='忽略')
        assert player.geometry()['chat_count']==0
        player.state(enabled=False)
        assert not player.geometry()['status_shown']
        player.open_popup()
        # Resize closes the popup and leaves the resulting icon within bounds.
        player.resize(720,460)
        assert not player.geometry()['popup_open']
        g=player.show_buttons()
        for r in g['buttons']:
            assert 0<=r['x1']<r['x2']<=g['width'] and 0<=r['y1']<r['y2']<=g['height']
        player.capture('resized-off')
        opts=player.get('options/script-opts')
        assert opts['overlay-test-keep']=='untouched'
        if mode=='uosc':
            assert opts['uosc-controls'].count('button:splay')==1
            assert 'button:danmaku' in opts['uosc-controls'] and 'fast_forward' in opts['uosc-controls']
        foreign_controls=None
        if mode=='uosc':
            # A later plugin/user runtime override keeps ownership of its
            # controls. Reinsert once, preserve its other option, then restore
            # that exact foreign declaration when our button is disabled.
            foreign_controls='menu,space,speed,space,button:foreign,fullscreen'
            opts['uosc-controls']=foreign_controls
            opts['overlay-test-later']='preserved'
            player.cmd('set_property','options/script-opts',opts)
            time.sleep(.25)
            changed=player.get('options/script-opts')
            assert changed['uosc-controls'].count('button:splay')==1
            assert 'button:foreign' in changed['uosc-controls']
            assert changed['overlay-test-later']=='preserved'
        player.cmd('script-message-to','splay_overlay','overlay-toggle-buttons')
        time.sleep(.2)
        assert not player.geometry()['visible'] and not player.geometry()['integrated']
        if mode=='uosc':
            assert player.get('options/script-opts')['uosc-controls']==foreign_controls
            assert player.get('options/script-opts')['overlay-test-later']=='preserved'
        player.capture('hidden')
        print(mode+': default-off, real icon/popup/rows, toggle, scoped/outside clicks, timeline, foreign menus, TTL, NUL, room/disconnect, resize, option preservation passed',flush=True)
    finally:
        player.close()
print('Offline overlay review passed. Mocked host; no network/protocol claim.')
job.close()
