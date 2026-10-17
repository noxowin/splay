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
parser.add_argument('--uosc-config', type=Path, default=ROOT / 'tests/ui/fixtures/uosc-layout.conf',
                    help='Synthetic layout by default; optionally use an explicit local configuration')
parser.add_argument('--fonts', type=Path, default=ROOT / '.local/uosc/fonts')
parser.add_argument('--mode', choices=('native','uosc','all'), default='all')
parser.add_argument('--output', type=Path, default=ROOT / '.local/v4-overlay')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
fixture = args.output / 'fixture'
fixture.mkdir(exist_ok=True)
(fixture / 'script-opts').mkdir(exist_ok=True)
shutil.copyfile(args.uosc_config, fixture / 'script-opts/uosc.conf')
shutil.copyfile(ROOT / 'tests/ui/overlay_host.lua', fixture / 'splay.lua')


class Player:
    def __init__(self, mode):
        self.mode = mode
        self.log = (args.output / (mode + '.log')).open('wb')
        self.pipe_name = r'\\.\pipe\splay_overlay_' + str(time.time_ns())
        command = [str(args.mpv), '--load-scripts=no', '--config-dir=' + str(fixture), '--ao=null', '--pause=yes',
                   '--force-window=yes', '--geometry=1100x700+50+50',
                   '--input-ipc-server=' + self.pipe_name, '--screenshot-format=png',
                   '--osd-fonts-dir=' + str(args.fonts), '--cursor-autohide=1800',
                   '--script=' + str(fixture / 'splay.lua'),
                   '--script=' + str(ROOT / 'scripts/splay_overlay.lua'),
                   '--script-opts=splay-overlay_chat_ttl=3,splay-overlay_message_ttl=3,overlay-test-keep=untouched',
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
                 'playlist_supported': True, 'playlist': {'files': ['电影第一集.mp4', '电影第二集.mp4'], 'index': 0, 'user': '小明'},
                 'local_file': '本机播放的电影.mp4',
                 'members': [{'username': '小明', 'room': '周末电影', 'ready': True, 'file': {'name': '电影第一集.mp4', 'duration': 120}},
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
        self.move(g['width'] / 2, g['height'] - 60)
        time.sleep(.15)
        g = self.geometry()
        if self.mode == 'native':
            assert g['visible'] and len(g['buttons']) == (2 if g['chat_available'] else 1), g
        else:
            assert g['integrated'] and not g['buttons'], g
        return g

    def open_popup(self):
        g=self.show_buttons()
        if self.mode=='native':
            r=g['buttons'][0]
            self.click((r['x1']+r['x2'])/2,(r['y1']+r['y2'])/2)
        else:
            # Synthetic fixture layout: after forward/space, before fixture-action. This
            # coordinate is calibrated against the saved real-window capture.
            self.click(g['width']-(368 if g['chat_available'] else 321), g['height']-60)
        if not self.geometry()['popup_open']: self.capture('popup-click-failed')
        assert self.geometry()['popup_open'], self.geometry()
        return self.geometry()

    def click_row(self,index):
        r=self.geometry()['rows'][index]
        self.click((r['x1']+r['x2'])/2,(r['y1']+r['y2'])/2)

    def click_chat(self):
        g=self.show_buttons()
        assert g['chat_available'], g
        if self.mode=='native':
            r=g['chat_button']
            self.click((r['x1']+r['x2'])/2,(r['y1']+r['y2'])/2)
        else:
            self.click(g['width']-321,g['height']-60)
        assert self.action()['value']=='chat' and not self.geometry()['popup_open'], self.action()

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
        g=player.geometry()
        assert g['room_panel_visible'] and g['chat_available'], g
        rows=g['room_rows']
        assert [r['color'] for r in rows if r['kind']=='member']==['80E692','7777FF','999999'], rows
        assert any('本机播放的电影.mp4' in r['text'] for r in rows), rows
        assert any('电影第一集.mp4' in r['text'] for r in rows), rows
        assert any(r['kind']=='playlist' and '1 / 2' in r['text'] for r in rows), rows
        # Network entries keep their protocol URL but the right panel must
        # never expose HTTP(S) userinfo, query tokens, or fragments.
        action_before=player.action()
        for url,label in [
            ('https://u:p@h/v.mp4?token=SECRET#PRIVATE','h/v.mp4'),
            ('HTTP://u%40x:p@h:81/a?SECRET=1#PRIVATE','h:81/a'),
            ('https://h/v.mp4?SECRET=1#PRIVATE','h/v.mp4'),
            ('https://h#PRIVATE','h'),
            ('https://u:p@h/a@b.mp4?SECRET','h/a@b.mp4'),
            ('本地文件.mp4','本地文件.mp4'),
        ]:
            player.state(playlist={'files':[url],'index':0})
            item=next(r['text'] for r in player.geometry()['room_rows'] if r['kind']=='playlist-file')
            assert item.strip()==label, (url,item)
            assert 'SECRET' not in item and 'PRIVATE' not in item and 'u:p' not in item
        assert player.action()==action_before
        player.state(playlist={'files':['https://u:p@h/v.mp4?token=SECRET#PRIVATE'],'index':0})
        player.capture('playlist-url-redacted')
        player.state()
        player.event(type='notice',id='n1',category='connection',text='已连接到同步房间')
        player.event(type='notice',id='n2',category='ready',text='小明已准备')
        player.event(type='playback',id='p1',username='小明',paused=True,position=3661)
        player.event(type='chat',id='c1',username='小明',text='大家晚上好！ 😊 👨‍👩‍👧‍👦 👍🏽 🇨🇳')
        player.event(type='chat',id='c2',username='朋友',text=r'ASS 100% {\pos(999,999)\c&H0000FF&}原样显示 \N 不换行')
        player.event(type='chat',id='c2',username='朋友',text='重复事件应忽略')
        assert player.geometry()['chat_count']==2
        player.show_buttons()
        player.capture('enabled-status-chat')
        player.open_popup()
        player.capture('popup-enabled')
        player.click_row(2)
        assert player.action()['value']=='ready' and not player.geometry()['popup_open']
        player.open_popup(); player.click_chat()
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
        assert player.geometry()['chat_count']==0 and player.geometry()['notification_count']==0
        assert player.geometry()['room_panel_visible'], player.geometry()
        # Running playback hides the right panel after cursor idle, and a real
        # mouse move brings it back. Pausing keeps it visible after the timer.
        player.cmd('set_property','pause',False)
        time.sleep(.25)
        assert player.geometry()['room_panel_visible'], player.geometry()
        time.sleep(2.0)
        assert not player.geometry()['room_panel_visible'] and not player.geometry()['status_shown'], player.geometry()
        player.event(type='notice',id='while-hidden',category='room',text='朋友加入了房间')
        assert player.geometry()['notification_count']==1 and player.geometry()['status_shown']
        player.capture('playing-idle-notice')
        player.move(160,140)
        assert player.geometry()['room_panel_visible']
        player.capture('playing-mouse-room')
        player.cmd('set_property','pause',True)
        time.sleep(3.2)
        assert player.geometry()['room_panel_visible'] and player.geometry()['notification_count']==0
        player.capture('paused-idle-room')
        # Both status regions respect the same explicit off option.
        player.cmd('script-message-to','splay_overlay','overlay-toggle-status')
        time.sleep(.15)
        assert not player.geometry()['status_shown'] and not player.geometry()['room_panel_visible']
        player.cmd('script-message-to','splay_overlay','overlay-toggle-status')
        # Cursor policy is read-only; no/FS-only prevent idle hiding where the
        # user's cursor also remains visible. Returning to playback grants grace.
        player.cmd('set_property','cursor-autohide','no')
        cursor_policy=player.get('cursor-autohide')
        player.cmd('set_property','pause',False)
        time.sleep(2.0)
        assert player.geometry()['room_panel_visible']
        assert player.get('cursor-autohide')==cursor_policy
        player.cmd('set_property','cursor-autohide',400)
        player.cmd('set_property','cursor-autohide-fs-only',True)
        time.sleep(.8)
        assert player.geometry()['room_panel_visible']
        player.cmd('set_property','cursor-autohide-fs-only',False)
        time.sleep(.4)
        assert not player.geometry()['room_panel_visible']
        player.cmd('set_property','pause',True)
        player.cmd('set_property','cursor-autohide',1800)
        player.event(type='chat',id='nul',username='朋友',text='前半\x00后半 \\u0000 100%')
        player.capture('nul-literal')
        player.state(room='另一个房间',members=[])
        assert player.geometry()['chat_count']==0 and not player.geometry()['playback_active']
        player.state(connection='disconnected',members=[])
        assert not player.geometry()['chat_available'] and not player.geometry()['room_panel_visible']
        if mode=='uosc': assert 'button:splay-chat' not in player.get('options/script-opts')['uosc-controls']
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
        player.state(room='多成员房间',local_file='很长的中文文件名'*20,
                     members=[{'username':'成员'+str(i)+'很长的名字'*10,'room':'多成员房间','ready':i%2==0,
                               'file':{'name':'电影文件名'*30+'.mp4'}} for i in range(20)],
                     playlist={'files':['很长的列表项目'*30],'index':0})
        bounded=player.geometry()
        assert bounded['room_panel_visible'] and bounded['room_panel']['x1']>=0
        assert bounded['room_panel']['x2']<=bounded['width'] and bounded['room_panel']['y2']<=bounded['height']*.56
        assert any(r['kind']=='more' for r in bounded['room_rows']), bounded
        assert all(len(r['text'])<40 for r in bounded['room_rows']), bounded
        player.capture('resized-room-bounded')
        binding_count=len([b for b in player.get('input-bindings') if b.get('owner')=='splay_overlay'])
        for i in range(8):
            player.state(chat_supported=i%2==0)
            assert player.geometry()['chat_available']==(i%2==0)
            if mode=='uosc':
                controls=player.get('options/script-opts')['uosc-controls'].split(',')
                assert controls.count('button:splay')==1 and controls.count('button:splay-chat')==(1 if i%2==0 else 0)
        assert len([b for b in player.get('input-bindings') if b.get('owner')=='splay_overlay'])==binding_count
        for i in range(6): player.event(type='notice',id='burst'+str(i),category='room',text='成员状态更新 '+str(i))
        assert player.geometry()['notification_count']==4
        player.state(enabled=False)
        opts=player.get('options/script-opts')
        assert opts['overlay-test-keep']=='untouched'
        if mode=='uosc':
            assert opts['uosc-controls'].split(',').count('button:splay')==1
            assert 'button:fixture-action' in opts['uosc-controls'] and 'fast_forward' in opts['uosc-controls']
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
            assert changed['uosc-controls'].split(',').count('button:splay')==1
            assert 'button:foreign' in changed['uosc-controls']
            assert changed['overlay-test-later']=='preserved'
        player.cmd('script-message-to','splay_overlay','overlay-toggle-buttons')
        time.sleep(.2)
        assert not player.geometry()['visible'] and not player.geometry()['integrated']
        if mode=='uosc':
            assert player.get('options/script-opts')['uosc-controls']==foreign_controls
            assert player.get('options/script-opts')['overlay-test-later']=='preserved'
        player.capture('hidden')
        print(mode+': transient TTL/dedup/bounds, colored room/files/playlist, pause/idle/mouse/cursor policy, chat icon clicks, popup/timeline/foreign menus, resize, binding stability and controls ownership passed',flush=True)
    finally:
        player.close()
print('Offline overlay review passed. Mocked host; no network/protocol claim.')
job.close()
