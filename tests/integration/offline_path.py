"""What a player does while it is not in a room: the resting core, the local
time offset and the password prompt, on a real mpv with the production DLL
and scripts.

While disconnected with no offset and no pending reconnect, the core only
waits for player events and does not watch playback. Nothing the user does in
that time may leak into a later offset or into the room they join next. The
core suites cannot see this: it lives between the adapter's event loop and a
real player.

A second player (DLL plus the observer from interop.py) sits in the room as
the reference for room time, on an unmodified official server protected by a
generated password. Everything is driven from outside the player: splay menu
actions and player commands over mpv's IPC, and real console key presses for
the offset and password prompts. Only processes in this harness's Windows job
are touched; all files live under a fresh .local directory.
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

from interop import Job, Player as Observer, ROOT, background_window, wait_for

# Prepended to copies of the production scripts. They only mirror what the
# scripts already receive into player properties; every message is still
# handled by the production code. A prompt is recorded with its text but never
# with what was typed, and a password result as having arrived, never with its
# token.
OVERLAY_PROBE = '''local register=mp.register_script_message
mp.register_script_message=function(name,fn)
    if name=='splay-state' then register(name,function(json)
        mp.set_property_native('user-data/splay-test-state',require('mp.utils').parse_json(json));fn(json)
    end) else register(name,fn) end
end
'''
MAIN_PROBE = '''local input=require 'mp.input'
for _,kind in ipairs({'get','select'}) do
    local original=input[kind]
    input[kind]=function(request)
        local status={kind=kind,prompt=request.prompt,submitted=false,closed=false}
        mp.set_property_native('user-data/splay-test-input',status)
        local submit,closed=request.submit,request.closed
        request.submit=function(value)
            status.submitted=true
            mp.set_property_native('user-data/splay-test-input',status)
            if submit then submit(value) end
        end
        request.closed=function(...)
            status.closed=true;mp.set_property_native('user-data/splay-test-input',status)
            if closed then closed(...) end
        end
        -- Only the length of the line, so a test can tell every key arrived
        -- without the probe ever holding what was typed.
        local edited=request.edited
        request.edited=function(text,...)
            status.length=#tostring(text or '')
            mp.set_property_native('user-data/splay-test-input',status)
            if edited then return edited(text,...) end
        end
        return original(request)
    end
end
local secret_count=0
local register=mp.register_script_message
mp.register_script_message=function(name,fn)
    if name=='splay-secret' then register(name,function(json)
        local value=require('mp.utils').parse_json(json) or {}
        secret_count=secret_count+1
        mp.set_property_native('user-data/splay-test-secret',{count=secret_count,
            cancelled=value.cancelled==true,failed=value.error~=nil,
            has_token=type(value.token)=='string' and value.token~='',saved=value.saved==true})
        fn(json)
    end) else register(name,fn) end
end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpv', type=Path, default=ROOT / '.local/mpv/runtime/mpv.exe')
    parser.add_argument('--python', type=Path, default=ROOT / '.venv/Scripts/python.exe')
    parser.add_argument('--upstream', type=Path, default=ROOT / '.local/upstream/syncplay-1.7.6')
    parser.add_argument('--plugin', type=Path, default=ROOT / 'build/splay_core.dll')
    parser.add_argument('--scripts', type=Path, default=ROOT / 'scripts', help='Directory with the three Lua scripts')
    parser.add_argument('--media', type=Path, default=ROOT / '.local/test-media.mp4')
    parser.add_argument('--language', choices=['zh-CN', 'en'],
                        help='Pin the interface language; default follows the system through language=auto')
    args = parser.parse_args()
    media = str(args.media)
    output = ROOT / '.local/integration' / ('offline-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6])
    config = output / 'isolated-mpv'
    (config / 'scripts').mkdir(parents=True)
    (config / 'script-opts').mkdir()
    env = dict(os.environ, APPDATA=str(output / 'appdata'), PYTHONUTF8='1', PYTHONIOENCODING='utf-8',
               PYTHONUNBUFFERED='1')
    Path(env['APPDATA']).mkdir()
    other_media = output / 'other-media.mp4'
    shutil.copy2(args.media, other_media)
    # Generated for this run's local server only; never printed or stored.
    password = 'offline-' + uuid.uuid4().hex
    room = 'offline-' + uuid.uuid4().hex[:8]
    job, logs, findings = Job(), [], []

    def note(text, **values):
        findings.append(dict(step=text, **values))
        print('OK:', text, json.dumps(values, ensure_ascii=False) if values else '', flush=True)

    def launch(name, command):
        log = (output / (name + '.log')).open('wb')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=background_window())
        job.assign(process)
        return process

    class Production:
        """Real mpv with the production DLL and all three scripts."""
        def __init__(self):
            self.serial, self.pipe = 0, None
            shutil.copy2(args.plugin, config / 'scripts/splay_core.dll')
            shutil.copy2(args.scripts / 'splay_playlist.lua', config / 'scripts/splay_playlist.lua')
            (config / 'scripts/splay_overlay.lua').write_text(
                OVERLAY_PROBE + (args.scripts / 'splay_overlay.lua').read_text(encoding='utf-8'), encoding='utf-8')
            (config / 'scripts/splay.lua').write_text(
                MAIN_PROBE + (args.scripts / 'splay.lua').read_text(encoding='utf-8'), encoding='utf-8')
            self.pipe_name = r'\\.\pipe\splay_offline_' + uuid.uuid4().hex
            self.process = launch('production', [args.mpv, '--load-scripts=no', '--config-dir=' + str(config),
                '--vo=null', '--ao=null', '--pause=yes', '--idle=yes', '--input-ipc-server=' + self.pipe_name,
                '--msg-level=all=warn', '--script=' + str(config / 'scripts/splay_core.dll'),
                '--script=' + str(config / 'scripts/splay.lua'), '--script=' + str(config / 'scripts/splay_overlay.lua'),
                '--script=' + str(config / 'scripts/splay_playlist.lua'), media])

            def opened():
                try:
                    self.pipe = open(self.pipe_name, 'r+b', buffering=0)
                    return True
                except OSError:
                    return False
            wait_for('production player IPC ready', opened)
            wait_for('production splay initialized', lambda: self.get('user-data/splay'))

        def cmd(self, *command):
            self.serial += 1
            self.pipe.write((json.dumps(dict(command=command, request_id=self.serial)) + '\n').encode())
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

        def state(self):
            return self.get('user-data/splay-test-state') or {}

        def action(self, name):
            self.cmd('script-message-to', 'splay', 'splay-action', name)

        def position(self):
            return self.get('time-pos') or 0

        def at(self, target, tolerance=.5):
            return abs(self.position() - target) < tolerance

        def seek(self, target):
            self.cmd('seek', target, 'absolute+exact')
            wait_for('player seeks to %g' % target, lambda: self.at(target))

        def play_for(self, seconds):
            self.cmd('set_property', 'pause', False)
            time.sleep(seconds)
            self.cmd('set_property', 'pause', True)
            time.sleep(.3)

        def offset(self):
            return self.state().get('time_offset')

        def step_offset(self, action, expected):
            # The step menus reopen themselves after applying; close them.
            self.action(action)
            wait_for('%s gives offset %g' % (action, expected), lambda: self.offset() == expected)
            self.cmd('keypress', 'ESC')

        def type_offset(self, text):
            # Real console keys into the production prompt.
            self.action('offset-input')
            wait_for('offset prompt opens', lambda: (lambda status: status.get('kind') == 'get' and not status.get('closed'))
                     (self.get('user-data/splay-test-input') or {}))
            wait_for('console is open for typing', lambda: self.get('user-data/mpv/console/open') is True)
            time.sleep(.4)
            self.cmd('keypress', 'Ctrl+a')
            self.cmd('keypress', 'Ctrl+k')
            for character in text:
                self.cmd('keypress', character)
            self.cmd('keypress', 'ENTER')
            wait_for('typed offset %s applies' % text, lambda: self.offset() == float(text))
            self.cmd('keypress', 'ESC')

        def password_prompt(self):
            """The open password prompt's status, if one is open."""
            status = self.get('user-data/splay-test-input') or {}
            prompt = status.get('prompt') or ''
            return status if status.get('kind') == 'get' and not status.get('closed') and \
                ('输入时可见' in prompt or 'visible while typing' in prompt) else None

        def open_prompt(self):
            self.action('password')
            status = wait_for('password prompt opens', self.password_prompt)
            wait_for('the mpv console takes the keys', lambda: self.get('user-data/mpv/console/open') is True)
            time.sleep(.4)
            return status

        def secret(self):
            return self.get('user-data/splay-test-secret') or {'count': 0}

        def type_keys(self, text):
            """Type text into the open console line, one key at a time.

            A key sent over IPC is now and then lost before it reaches the
            console. The probe reports the line's length, so a short line is
            cleared and typed again instead of being submitted wrong.
            """
            for attempt in range(3):
                for character in text:
                    self.cmd('keypress', character)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if (self.get('user-data/splay-test-input') or {}).get('length') == len(text):
                        return
                    time.sleep(.05)
                print('typed again: the console line has the wrong length (attempt %d)' % (attempt + 1), flush=True)
                self.cmd('keypress', 'Ctrl+a')
                self.cmd('keypress', 'Ctrl+k')
                time.sleep(.3)
            raise AssertionError('keys typed into the console kept getting lost')

        def finish_prompt(self, how, text=''):
            """Type into the open prompt and leave it with Enter or Esc. After
            Enter, return how long the core's answer took to reach the
            interface; after Esc, check that the core is never asked."""
            before = self.secret()['count']
            if text:
                self.type_keys(text)
            self.cmd('keypress', 'ENTER' if how == 'enter' else 'ESC')
            wait_for('password prompt closes', lambda: not self.password_prompt())
            closed = time.perf_counter()
            if how != 'enter':
                time.sleep(.5)
                assert self.secret()['count'] == before, 'a cancelled prompt must not reach the core'
                assert self.get('user-data/mpv/console/open') is not True
                return None
            wait_for('its result reaches the interface', lambda: self.secret()['count'] == before + 1)
            return round(time.perf_counter() - closed, 3)

    def room_position():
        return reference.read().get('position') or 0

    def room_at(target, tolerance=1):
        return abs(room_position() - target) < tolerance

    def room_events_by(name):
        return [event for event in reference.read()['events'] if event.get('type') == 'playback' and event.get('username') == name]

    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        launch('server', [args.python, args.upstream / 'syncplayServer.py', '--port', port, '--ipv4-only',
                          '--interface-ipv4', '127.0.0.1', '--password', password])

        def listening():
            with socket.socket() as client:
                return client.connect_ex(('127.0.0.1', port)) == 0
        wait_for('unmodified password-protected official server listens', listening)
        (config / 'script-opts/splay.conf').write_text(
            'host=127.0.0.1\nport=%d\nusername=offline\nroom=%s\ntls=off\nremember_password=no\nauto_reconnect=no\n'
            % (port, room) + ('language=%s\n' % args.language if args.language else ''), encoding='utf-8')

        p = Production()
        assert p.get('user-data/splay').get('enabled') is False
        wait_for('media loaded', lambda: (p.get('duration') or 0) > 100)
        p.action('toggle-enabled')
        wait_for('splay enabled, still disconnected', lambda: p.state().get('enabled') is True)
        assert p.state()['connection'] == 'disconnected' and p.offset() == 0
        language = p.state()['settings']['language']
        assert language == (args.language or language) and language in ('zh-CN', 'en'), language

        # ---- Local time offset with no connection ---------------------------------
        # Setting an offset relocates only this player: local = reference + offset.
        p.seek(50)
        for step in (1, 2, 3):
            p.step_offset('offset-plus', step)
        wait_for('three +1 steps move the player from 50 to 53', lambda: p.at(53))
        assert p.state()['connection'] == 'disconnected' and p.get('pause') is True
        p.type_offset('20')
        wait_for('typing 20 moves the player to 70', lambda: p.at(70))
        assert p.state()['connection'] == 'disconnected' and p.get('pause') is True
        note('offline offset by menu steps and by the prompt relocates the paused player', position=p.position())

        p.play_for(2.2)
        played = p.position()
        assert 71.5 < played < 74.5, played
        p.seek(60)
        time.sleep(1)
        assert p.at(60) and p.get('pause') is True, 'nothing may pull an offline player back'
        assert not p.state().get('error') and p.state().get('time_offset_boundary') is not True
        note('offline play, pause and seek behave normally while an offset is set', after_play=played)

        p.step_offset('offset-reset', 0)
        wait_for('reset takes the offset off the current position: 60 - 20', lambda: p.at(40))
        # Offset 0 and no connection: the core rests and does not see this seek.
        # The next offset must start from where the player is, not from the
        # reference the earlier offset left behind (that put it at 39).
        time.sleep(1.5)
        p.seek(100)
        time.sleep(1.5)
        started = time.perf_counter()
        p.step_offset('offset-minus', -1)
        response = round(time.perf_counter() - started, 3)
        time.sleep(.8)
        assert p.at(99), p.position()
        note('an offline seek made while the core rested is where the next offset starts', position=p.position(),
             command_to_state_seconds=response)

        p.cmd('loadfile', str(other_media))
        wait_for('other media loads offline', lambda: p.get('path') == str(other_media) and (p.get('duration') or 0) > 100)
        wait_for('changing media clears the offset', lambda: p.offset() == 0)
        p.cmd('loadfile', media)
        wait_for('original media loads again', lambda: p.get('path') == media and (p.get('duration') or 0) > 100)
        p.cmd('set_property', 'pause', True)
        assert p.offset() == 0
        note('loading different media offline clears the offset')

        # ---- Password prompt with no connection -----------------------------------
        assert not p.password_prompt() and p.get('user-data/mpv/console/open') is not True
        prompt = p.open_prompt()['prompt']
        # The prompt is the mpv console's, in the interface language, and says
        # that what is typed stays visible.
        visible = '(visible while typing)' if language == 'en' else '（输入时可见）'
        assert visible in prompt and str(port) in prompt and prompt.isascii() == (language == 'en'), prompt
        # The player stays usable while the prompt is open.
        p.seek(10)
        p.play_for(1.2)
        assert p.position() > 10.6, p.position()
        p.seek(10)
        assert p.password_prompt() and p.state()['connection'] == 'disconnected'
        p.finish_prompt('escape', 'typed-then-cancelled')
        note('the password prompt is the mpv console in the interface language, the player works while it is open, '
             'Esc cancels without reaching the core', language=language, prompt=prompt)

        p.open_prompt()
        p.action('password')
        time.sleep(.5)
        wait_for('a prompt is open after asking twice', p.password_prompt)
        p.action('toggle-enabled')
        wait_for('disabling splay closes the open prompt', lambda: not p.password_prompt() and
                 p.get('user-data/mpv/console/open') is not True)
        wait_for('splay disabled', lambda: p.state().get('enabled') is False)
        assert p.secret()['count'] == 0, 'no prompt so far has reached the core'
        p.action('toggle-enabled')
        wait_for('splay enabled again', lambda: p.state().get('enabled') is True)
        note('asking twice leaves one prompt; disabling splay closes it')

        p.open_prompt()
        p.finish_prompt('enter', 'wrong-' + uuid.uuid4().hex)
        assert p.secret()['has_token'] is True and p.secret()['cancelled'] is False and p.secret()['saved'] is False
        p.action('connect')
        wait_for('the official server refuses a wrong password from the prompt', lambda: p.state().get('connection') == 'error')
        assert p.get('path') == media
        note('a wrong password from the prompt is refused by the server', error=p.state().get('error'))

        # ---- Reference player: in the room first, paused at 40 ---------------------
        reference = Observer(output, 'plugin')
        launch('reference', [args.mpv, '--no-config', '--vo=null', '--ao=null', '--pause=yes', '--idle=yes',
                             '--script=' + str(args.plugin), '--script=' + str(reference.script), media])
        wait_for('reference player loads media', lambda: reference.read().get('duration', 0) > 100)
        reference.splay('room-policy', pause_on_join=False, pause_on_leave=False)
        reference.splay('connect', host='127.0.0.1', port=port, username='reference', room=room, password=password, tls='off')
        wait_for('reference player connects', lambda: reference.read()['state'].get('connection') == 'connected')
        time.sleep(2.5)  # the adapter ignores local changes in the first second of a connection
        reference.command('seek', 40, 'absolute+exact')
        wait_for('reference player seeks to 40', lambda: room_at(40, .5))
        time.sleep(2.5)
        assert room_at(40, .5), 'the room must have taken the seek to 40'

        # ---- Joining after resting ---------------------------------------------------
        # Play, pause and seek while the core rests, then join. The player takes
        # the room's position; nothing it did offline reaches the room.
        p.play_for(1.2)
        p.seek(90)
        time.sleep(1.5)
        p.open_prompt()
        delay = p.finish_prompt('enter', password)
        assert p.secret()['has_token'] is True and p.secret()['saved'] is False
        assert not (config / 'splay-credentials.json').exists(), 'remember_password=no must not write a credential file'
        p.action('connect')
        wait_for('joins with the password from the prompt', lambda: p.state().get('connection') == 'connected')
        wait_for('the joining player takes the room position 40', lambda: p.at(40, 1))
        time.sleep(2.5)
        assert room_at(40) and reference.read()['paused'] is True, 'joining must not move or start the room'
        assert p.at(40, 1) and p.get('pause') is True and p.get('path') == media
        assert not [event for event in room_events_by('offline') if event.get('seek')], room_events_by('offline')
        note('joining after offline play, pause and seek: the player takes room time 40, the room is untouched',
             result_after_enter_seconds=delay)
        # From here on the player's own gestures do reach the room.
        p.cmd('set_property', 'pause', False)
        wait_for('playing after the join starts the room', lambda: reference.read()['paused'] is False)
        time.sleep(1.5)
        p.cmd('set_property', 'pause', True)
        wait_for('pausing pauses the room', lambda: reference.read()['paused'] is True)
        time.sleep(1.5)
        resumed = room_position()
        assert resumed > 40.5 and abs(p.position() - resumed) < 1.5, (p.position(), resumed)
        note('after the join, play and pause reach the room and both players agree', room=resumed, local=p.position())

        # ---- Leaving with no offset --------------------------------------------------
        # The core rests while still remembering the room's last position. A
        # later offline seek must be where the next offset starts.
        p.action('disconnect')
        wait_for('disconnects', lambda: p.state().get('connection') == 'disconnected')
        time.sleep(1.5)
        p.seek(120)
        time.sleep(1.5)
        p.step_offset('offset-plus', 1)
        time.sleep(.8)
        assert p.at(121), p.position()
        assert room_at(resumed), 'an offline player must not move the room'
        note('after leaving with no offset, an offline seek then +1 starts from the player, not the room',
             local=p.position(), room=room_position())

        # ---- Joining with an offset set offline --------------------------------------
        p.type_offset('20')
        p.seek(10)
        time.sleep(1)
        assert p.at(10), 'an offline seek with an offset set must stay where the user put it'
        p.action('connect')
        wait_for('joins again with the password held for this process', lambda: p.state().get('connection') == 'connected')
        wait_for('local time is room time + 20', lambda: p.at(resumed + 20, 1))
        time.sleep(2)
        assert room_at(resumed) and p.at(resumed + 20, 1) and p.offset() == 20
        assert p.get('pause') is True and reference.read()['paused'] is True
        note('joining with an offset set offline keeps local = room + 20 and leaves the room alone',
             local=p.position(), room=room_position())
        time.sleep(1)
        p.seek(100)
        wait_for('a local seek to 100 moves the room to 80', lambda: room_at(80))
        reference.command('seek', 30, 'absolute+exact')
        wait_for('a room seek to 30 moves the local player to 50', lambda: p.at(50, 1))
        note('in the room both directions keep the offset')

        p.action('disconnect')
        wait_for('disconnects with the offset set', lambda: p.state().get('connection') == 'disconnected')
        assert p.offset() == 20
        p.seek(120)
        time.sleep(2)
        assert room_at(30) and p.at(120), 'an offline player must not move the room'
        p.action('connect')
        wait_for('reconnects', lambda: p.state().get('connection') == 'connected')
        wait_for('the kept offset applies again: 30 + 20', lambda: p.at(50, 1))
        time.sleep(1.5)
        assert room_at(30) and p.offset() == 20
        p.step_offset('offset-reset', 0)
        wait_for('clearing the offset returns the player to room time 30', lambda: p.at(30, 1))
        time.sleep(1)
        assert room_at(30), 'changing the offset must not seek the room'
        note('the offset survives a disconnect and reconnect, and clearing it does not move the room')

        # ---- Quitting with the prompt open -------------------------------------------
        p.action('disconnect')
        wait_for('disconnects before quitting', lambda: p.state().get('connection') == 'disconnected')
        p.open_prompt()
        started = time.perf_counter()
        p.pipe.write(b'{"command":["quit"]}\n')
        p.process.wait(timeout=10)
        assert p.process.returncode == 0, p.process.returncode
        note('quitting mpv with the password prompt open exits cleanly', seconds=round(time.perf_counter() - started, 3))

        for log in logs:
            log.flush()
        text = (output / 'production.log').read_text(encoding='utf-8', errors='replace')
        assert 'Lua error' not in text and 'stack traceback' not in text, text[-2000:]
        assert password not in text and password not in (output / 'reference.log').read_text(encoding='utf-8', errors='replace')
        (output / 'result.json').write_text(json.dumps({'passed': True, 'official_version': '1.7.6', 'findings': findings},
                                                       ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: resting core, offline time offset and password prompt on a real player:', output, flush=True)
    finally:
        job.close()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
