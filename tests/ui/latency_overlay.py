"""Actual mpv overlay presentation checks, with an explicitly mocked host.

This verifies visible row semantics and bounds only, not network measurement.
The process runs minimized and never connects to a server.
"""
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/integration'))
from interop import Job, wait_for


def main():
    output = ROOT / '.local/latency-overlay' / uuid.uuid4().hex[:8]
    output.mkdir(parents=True)
    pipe_name = r'\\.\pipe\splay-latency-' + uuid.uuid4().hex
    job = Job()
    log = (output / 'mpv.log').open('wb')
    process = subprocess.Popen([str(ROOT / '.local/mpv/runtime/mpv.exe'), '--no-config', '--load-scripts=no',
        '--force-window=yes', '--window-minimized=yes', '--geometry=1100x800', '--ao=null', '--pause=yes',
        '--input-ipc-server=' + pipe_name, '--script=' + str(ROOT / 'scripts/splay_overlay.lua'),
        str(ROOT / '.local/test-media.mp4')], stdout=log, stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW)
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
        'latency': {'enabled': False, 'rtt_ms': 42, 'reported': True, 'stale': False},
        'members': [{'username': 'me', 'room': 'synthetic', 'ready': True},
                    {'username': 'peer', 'room': 'synthetic', 'latency': {'rtt_ms': 125, 'reported': True}},
                    {'username': 'official', 'room': 'synthetic', 'latency': {'rtt_ms': None, 'reported': False}}]}

    def publish():
        command('script-message-to', 'splay_overlay', 'splay-state', json.dumps(state))
        time.sleep(.15)
        try:
            return command('get_property', 'user-data/splay-overlay')
        except AssertionError as error:
            if 'property not found' in str(error):
                return {}
            raise

    def latency_rows(snapshot):
        return {row['username']: row['text'] for row in snapshot.get('room_rows', []) if row.get('kind') == 'latency'}

    try:
        wait_for('minimized offline mpv IPC opens', connect)
        wait_for('overlay publishes bounded room geometry', lambda: publish().get('room_panel_visible'))
        assert not latency_rows(publish()), 'Default off should show no latency rows'
        state['latency']['enabled'] = True
        snapshot = publish()
        values = latency_rows(snapshot)
        assert '42 ms' in values['me'] and '自报' not in values['me']
        assert '125 ms' in values['peer'] and '自报' in values['peer']
        assert '未上报' in values['official']
        state['latency'].update(rtt_ms=None, reported=False)
        state['members'][1]['latency'].update(rtt_ms=None, stale=True)
        values = latency_rows(publish())
        assert '测量中' in values['me'] and '已过期' in values['peer']
        state['members'][1]['latency'].update(rtt_ms=-10, stale=False)
        assert '未上报' in latency_rows(publish())['peer']
        state['latency']['enabled'] = False
        assert not latency_rows(publish())
        (output / 'result.json').write_text(json.dumps({'passed': True, 'network_mocked': True,
            'numeric_rows': snapshot['room_rows'], 'default_off': True, 'unknown_and_stale': True},
            ensure_ascii=False, indent=2), encoding='utf-8')
        print('PASS: actual mpv overlay default-off, self/peer labels, unknown, stale and re-disable:', output)
    finally:
        if pipe:
            pipe.close()
        job.close()
        process.wait(timeout=5)
        log.close()


if __name__ == '__main__':
    main()
