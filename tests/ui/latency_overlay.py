"""Actual mpv overlay presentation checks, with an explicitly mocked host.

This verifies visible row semantics and bounds only, not network measurement.
The process runs minimized and never connects to a server.
"""
import json
import argparse
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/integration'))
from interop import Job, background_window, wait_for


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / '.local/latency-overlay' / uuid.uuid4().hex[:8])
    opts = parser.parse_args()
    output = opts.output
    output.mkdir(parents=True)
    pipe_name = r'\\.\pipe\splay-latency-' + uuid.uuid4().hex
    job = Job()
    log = (output / 'mpv.log').open('wb')
    process = subprocess.Popen([str(ROOT / '.local/mpv/runtime/mpv.exe'), '--no-config', '--load-scripts=no',
        '--force-window=yes', '--window-minimized=yes', '--geometry=1100x800', '--ao=null', '--pause=yes',
        '--input-ipc-server=' + pipe_name, '--script=' + str(ROOT / 'scripts/splay_overlay.lua'),
        str(ROOT / '.local/test-media.mp4')], stdout=log, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW, startupinfo=background_window(minimized=True))
    job.assign(process)
    pipe = None
    serial = 0

    def command(*values):
        nonlocal serial
        serial += 1
        pipe.write((json.dumps({'command': list(values), 'request_id': serial}) + '\n').encode())
        while True:
            value = json.loads(pipe.readline())
            if value.get('request_id') == serial:
                assert value.get('error') == 'success', value
                return value.get('data')

    def connect():
        nonlocal pipe
        try:
            pipe = open(pipe_name, 'r+b', buffering=0)
            return True
        except OSError:
            return False

    state = {'schema': 1, 'enabled': True, 'connection': 'connected', 'room': 'synthetic', 'username': 'me',
        'members': [{'username': 'me', 'room': 'synthetic', 'ready': True},
                    {'username': 'peer', 'room': 'synthetic'},
                    {'username': 'official', 'room': 'synthetic'}]}
    # Round-trip times travel in their own message; members without a report are absent.
    latency = {'schema': 1, 'enabled': False, 'self': {'rtt_ms': 42, 'reported': True, 'stale': False},
               'members': {'peer': {'rtt_ms': 125, 'reported': True}}}

    def snapshot_now():
        time.sleep(.15)
        try:
            return command('get_property', 'user-data/splay-overlay')
        except AssertionError as error:
            if 'property not found' in str(error):
                return {}
            raise

    def publish_latency(raw=None):
        command('script-message-to', 'splay_overlay', 'splay-latency', json.dumps(latency) if raw is None else raw)
        return snapshot_now()

    def publish():
        command('script-message-to', 'splay_overlay', 'splay-state', json.dumps(state))
        return publish_latency()

    def latency_rows(snapshot):
        return {row['username']: row['latency'] for row in snapshot.get('room_rows', [])
                if row.get('kind') == 'member' and row.get('latency')}

    try:
        wait_for('minimized offline mpv IPC opens', connect)
        wait_for('overlay publishes bounded room geometry', lambda: publish().get('room_panel_visible'))
        assert not latency_rows(publish()), 'Default off should show no latency rows'
        latency['enabled'] = True
        # The latency message alone, with no state resent, updates the visible rows.
        values = latency_rows(publish_latency())
        assert values['me']=='42 ms' and values['peer']=='125 ms',values
        assert 'official' not in values
        latency['self']['rtt_ms'], latency['members']['peer']['rtt_ms'] = 57, 260
        values = latency_rows(publish_latency())
        assert values['me']=='57 ms' and values['peer']=='260 ms',values
        for malformed in ('', '{', '[]', json.dumps(dict(latency, schema=2)), json.dumps({'schema': 1, 'enabled': True})):
            assert latency_rows(publish_latency(malformed)) == values, malformed
        # A state without any latency fields keeps the values already received.
        command('script-message-to', 'splay_overlay', 'splay-state', json.dumps(state))
        assert latency_rows(snapshot_now()) == values
        latency['self']['rtt_ms'], latency['members']['peer']['rtt_ms'] = 42, 125
        snapshot = publish_latency()
        values = latency_rows(snapshot)
        assert values['me']=='42 ms' and values['peer']=='125 ms',values
        members={r['username']:r for r in snapshot['room_rows'] if r['kind']=='member'}
        assert members['me']['latency_color']=='80E692' and members['peer']['latency_color']=='75DAFF',members
        state['members'][0]['ready']=False
        changed=publish()
        changed_me=next(r for r in changed['room_rows'] if r.get('username')=='me' and r['kind']=='member')
        assert changed_me['color']!=members['me']['color'] and changed_me['latency_color']==members['me']['latency_color']
        assert len({r['duration_x'] for r in changed['room_rows'] if r['kind']=='member'})==1
        assert not any(row.get('kind') == 'latency' for row in snapshot['room_rows'])
        assert next(row['text'] for row in snapshot['room_rows'] if row['kind'] == 'room') == 'synthetic'
        long_name = 'peer-with-a-very-long-name-' * 8
        state['members'][1]['username'] = long_name
        latency['members'][long_name] = latency['members'].pop('peer')
        values = latency_rows(publish())
        assert values[long_name]=='125 ms', values
        state['members'][1]['username'] = 'peer'
        latency['members']['peer'] = latency['members'].pop(long_name)
        latency['self'].update(rtt_ms=None, reported=False)
        latency['members']['peer'].update(rtt_ms=None, stale=True)
        values = latency_rows(publish())
        assert not values,values
        latency['members']['peer'].update(rtt_ms=-10, stale=False)
        assert 'peer' not in latency_rows(publish())
        latency['members']['peer'].update(rtt_ms=125)
        assert latency_rows(publish()).get('peer') == '125 ms'
        del latency['members']['peer']
        assert 'peer' not in latency_rows(publish()), 'a member that withdrew its report shows none'
        latency['enabled'] = False
        assert not latency_rows(publish())
        state['local_media'] = {'loaded': True, 'title': '本机影片.mp4', 'duration': 120}
        state['members'][1]['media'] = {'loaded': True, 'title': '同伴影片.mp4', 'duration': 132.3,
                                       'check': 'duration_mismatch', 'duration_delta': 12.3}
        state['members'][2]['media'] = {'loaded': True, 'title': '名称未提供', 'check': 'unknown'}
        media_snapshot = publish()
        summary = next(row['text'] for row in media_snapshot['room_rows']
                       if row['kind'] == 'media-summary' and row['username'] == 'peer')
        assert '时长不同' in summary and '对方长12.3秒' in summary, summary
        assert not any(row['kind'] == 'autostart' for row in media_snapshot['room_rows'])
        state['autostart'] = {'enabled': True, 'pending': True, 'remaining': 5, 'delay': 5, 'reason': 'countdown', 'participants': 3}
        countdown_snapshot = publish()
        assert countdown_snapshot['autostart_remaining'] == 5
        assert any(row['kind'] == 'autostart' and '5 秒' in row['text'] for row in countdown_snapshot['room_rows'])
        assert countdown_snapshot['notification_count'] == media_snapshot['notification_count'] == 0
        state['autostart'].update(remaining=2)
        assert publish()['autostart_remaining'] == 2
        state['autostart'].update(pending=False, reason='waiting-reset')
        assert not any(row['kind'] == 'autostart' for row in publish()['room_rows'])
        state['autostart'].update(enabled=False, reason='disabled')
        assert not any(row['kind'] == 'autostart' for row in publish()['room_rows'])
        (output / 'result.json').write_text(json.dumps({'passed': True, 'network_mocked': True,
            'numeric_rows': snapshot['room_rows'], 'default_off': True, 'unknown_and_stale': True,
            'media_delta_rows': media_snapshot['room_rows'], 'countdown_rows': countdown_snapshot['room_rows'],
            'autostart_default_off': True, 'countdown_no_notification_spam': True},
            ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: actual mpv overlay default-off, inline latency, name clipping, unknown, stale and re-disable:', output)
    finally:
        if pipe:
            pipe.close()
        job.close()
        process.wait(timeout=5)
        log.close()


if __name__ == '__main__':
    main()
