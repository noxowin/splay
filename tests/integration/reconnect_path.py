"""Real mpv adapter reconnect checks with isolated, deterministic TCP fixtures.

This deliberately tests failures rather than upstream server compatibility.
No user configuration or visible player is used. --exhaustion adds the actual
77-second retry schedule; policy tests cover it without wall-clock delays too.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import time
import uuid

from interop import Job, Player, ROOT, wait_for


class Fixture:
    def __init__(self, port=0, reject=False, tls_reject=False, tls_context=None):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', port))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(.1)
        self.stop = threading.Event()
        self.connections, self.hellos, self.messages, self.clients = 0, [], [], []
        self.reject, self.tls_reject, self.assigned = reject, tls_reject, None
        self.tls_context = tls_context
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            self.clients.append(client)
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client):
        try:
            with client, client.makefile('rwb', buffering=0) as stream:
                while not self.stop.is_set():
                    line = stream.readline()
                    if not line:
                        return
                    message = json.loads(line)
                    self.messages.append(message)
                    if 'TLS' in message:
                        if self.tls_context:
                            stream.write(b'{"TLS":{"startTLS":"true"}}\r\n')
                            with self.tls_context.wrap_socket(client, server_side=True) as secure:
                                data = secure.recv(4096)
                                if data:
                                    self.hellos.append({'unexpected_tls_application_data': True})
                            return
                        stream.write(b'{"TLS":{"startTLS":"false"}}\r\n')
                    if 'Hello' in message:
                        hello = message['Hello']
                        self.hellos.append(hello)
                        if self.reject:
                            stream.write(b'{"Error":"Password rejected"}\r\n')
                            return
                        room = self.assigned or hello['room']['name']
                        stream.write((json.dumps({'Hello': {'username': hello['username'], 'room': {'name': room}, 'version': '1.7.6'}})+'\r\n').encode())
                    if 'Set' in message and 'room' in message['Set']:
                        # The public command's effective room is echoed upstream.
                        room = message['Set']['room']['name']
                        stream.write((json.dumps({'Set': {'user': {'reconnect-test': {'room': {'name': room}}}}})+'\r\n').encode())
        except (OSError, ValueError):
            pass

    def drop(self):
        for client in list(self.clients):
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def close(self):
        self.stop.set()
        self.drop()
        self.listener.close()
        self.thread.join(2)


def unused_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def self_signed_context(output):
    # Development-only dependency, already used by the transport certificate test.
    import datetime
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1))
            .not_valid_after(now+datetime.timedelta(hours=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
            .sign(key, hashes.SHA256()))
    certificate, private = output/'fixture-certificate.pem', output/'fixture-key.pem'
    certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private)
    return context


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mpv', type=Path, default=ROOT/'.local/mpv/runtime/mpv.exe')
    parser.add_argument('--plugin', type=Path, default=ROOT/'build/splay_core.dll')
    parser.add_argument('--exhaustion', action='store_true')
    args = parser.parse_args()
    output = ROOT/'.local/reconnect'/('run-'+uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    player = Player(output, 'plugin')
    player.script.write_text(player.script.read_text(encoding='utf-8').replace(
        "duration=mp.get_property_native('duration'), state=state",
        "duration=mp.get_property_native('duration'), speed=mp.get_property_native('speed'), state=state"), encoding='utf-8')
    job, fixtures = Job(), []
    log = (output/'mpv.log').open('wb')
    env = dict(os.environ, APPDATA=str(output/'appdata'))
    process = subprocess.Popen(list(map(str, [args.mpv, '--no-config', '--load-scripts=no',
        '--vo=null', '--ao=null', '--pause=yes', '--idle=yes', '--speed=1.25', '--start=9',
        '--script='+str(args.plugin), '--script='+str(player.script), ROOT/'.local/test-media.mp4'])),
        cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
    job.assign(process)

    def state():
        return player.read()['state']

    def connect(port, room='base', tls='off', auto=True):
        player.splay('connect', host='127.0.0.1', port=port, username='reconnect-test', room=room,
                     tls=tls, auto_reconnect=auto)

    def fixture(**options):
        value = Fixture(**options)
        fixtures.append(value)
        return value

    def pending():
        return state().get('reconnect', {}).get('pending')

    try:
        wait_for('real mpv initializes disconnected', lambda: state().get('connection') == 'disconnected')
        wait_for('caller media start position loads', lambda: player.read().get('position') is not None)
        baseline = player.read()
        assert baseline['path'] == str(ROOT/'.local/test-media.mp4') and baseline['paused'] is True
        assert baseline['speed'] == 1.25 and abs(baseline['position']-9) < .5
        time.sleep(.3)
        assert state()['connection'] == 'disconnected' and not pending()
        server = fixture()
        server.assigned = '+assigned:ABCDEFGHIJKL'
        connect(server.port)
        wait_for('explicit connect completes Hello', lambda: state().get('connection') == 'connected')
        server.drop()
        wait_for('unexpected close schedules retry 1 at 2 seconds', lambda: pending() and state()['reconnect']['attempt'] == 1)
        wait_for('automatic retry completes Hello', lambda: len(server.hellos) == 2 and state().get('connection') == 'connected')
        assert server.hellos[1]['room']['name'] == '+assigned:ABCDEFGHIJKL'
        assert state()['ready'] is False and state()['is_controller'] is False
        after = player.read()
        assert after['path'] == baseline['path'] and after['paused'] is True
        assert after['speed'] == baseline['speed']
        assert abs(after['position']-baseline['position']) < .5
        assert 'speed' in state()['warning']

        # A room switch on a live connection is retained by the next Hello.
        server.assigned = None
        player.splay('room', room='changed-room')
        wait_for('room switch applies', lambda: state().get('room') == 'changed-room')
        server.drop()
        wait_for('room retry pending', pending)
        wait_for('retry joins current room', lambda: len(server.hellos) == 3 and state().get('connection') == 'connected')
        assert server.hellos[-1]['room']['name'] == 'changed-room'

        server.drop()
        wait_for('retry available to cancel', pending)
        player.splay('disconnect')
        wait_for('explicit disconnect cancels retry immediately', lambda: state()['connection'] == 'disconnected' and not pending())
        count = server.connections
        time.sleep(2.4)
        assert server.connections == count

        # Initial TCP failure is retryable; a later available listener receives it.
        port = unused_port()
        connect(port, room='late-server')
        wait_for('initial TCP error schedules retry', pending)
        late = fixture(port=port)
        wait_for('initial failure recovers when server becomes available', lambda: len(late.hellos) == 1 and state()['connection'] == 'connected')
        late.drop()
        wait_for('endpoint switch has an old pending retry', pending)
        replacement = fixture()
        connect(replacement.port, room='replacement')
        wait_for('new endpoint connects', lambda: len(replacement.hellos) == 1 and state()['connection'] == 'connected')
        count = late.connections
        time.sleep(2.4)
        assert late.connections == count and state()['room'] == 'replacement'

        rejected = fixture(reject=True)
        connect(rejected.port)
        wait_for('server authentication rejection is permanent', lambda: state()['connection'] == 'error' and 'rejected' in state()['error'])
        assert not pending()
        time.sleep(2.4)
        assert rejected.connections == 1
        tls = fixture(tls_reject=True)
        connect(tls.port, tls='require')
        wait_for('required TLS rejection is permanent', lambda: state()['connection'] == 'error' and 'TLS' in state()['error'])
        assert not pending() and not tls.hellos
        time.sleep(2.4)
        assert tls.connections == 1
        certificate = fixture(tls_context=self_signed_context(output))
        connect(certificate.port, tls='prefer')
        wait_for('self-signed TLS certificate failure stops automatic retry',
                 lambda: state()['connection'] == 'error' and 'certificate validation failed' in state()['error'])
        assert not pending() and not certificate.hellos
        time.sleep(2.4)
        assert certificate.connections == 1 and not certificate.hellos

        disabled_port = unused_port()
        connect(disabled_port, auto=False)
        wait_for('disabled automatic retry leaves transient failure stopped', lambda: state()['connection'] == 'error' and state()['port'] == disabled_port)
        assert state()['reconnect']['enabled'] is False and not pending()
        connect(unused_port())
        wait_for('retry can be disabled while pending', pending)
        player.splay('reconnect-disable')
        wait_for('disable immediately clears pending timer', lambda: not pending() and not state()['reconnect']['enabled'])

        if args.exhaustion:
            started = time.monotonic()
            connect(unused_port())
            wait_for('five real retries exhaust without endless background activity',
                     lambda: state()['reconnect']['attempt'] == 5 and not pending() and 'limit' in state()['reconnect']['reason'], seconds=90)
            assert time.monotonic()-started >= 76
        (output/'result.json').write_text(json.dumps({'passed': True, 'exhaustion': args.exhaustion, 'state': state()}, indent=2), encoding='utf-8')
        print('PASS: reconnect adapter suite; artifacts:', output)
    finally:
        for server in fixtures:
            server.close()
        if process.poll() is None:
            player.command('quit')
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        job.close()
        log.close()


if __name__ == '__main__':
    main()
