"""Run against a compiled tests/net/driver.cpp (argument 1). No external packages."""
import socket
import subprocess
import sys
import threading
import time

def run(mode, handler, extra=()):
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    failures = []
    def serve():
        try:
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(5)
                handler(conn)
        except Exception as exc:
            failures.append(exc)
        finally:
            listener.close()
    worker = threading.Thread(target=serve)
    worker.start()
    result = subprocess.run([sys.argv[1], str(listener.getsockname()[1]), mode, *extra], capture_output=True, text=True, timeout=8)
    worker.join(6)
    assert not failures, failures
    assert result.returncode == 0, result.stderr
    return result.stdout

def receive_line(conn):
    data = b''
    while not data.endswith(b'\n'):
        data += conn.recv(1)
    return data

def plain(conn):
    assert receive_line(conn) == b'{"hello":1}\r\n'
    for part in [b'{"a":', b'1}\r', b'\n{"b":2}\r\n']:
        conn.sendall(part)
        time.sleep(.02)
out = run('off', plain)
assert '0:0:' in out and '1:0:{"a":1}' in out and '1:0:{"b":2}' in out, out
# localhost normally resolves IPv6 first on Windows. The listener is IPv4-only:
# a refused first candidate must promptly fall through to the usable address.
out = run('off', plain, ('localhost',))
assert '0:0:' in out and '1:0:{"a":1}' in out, out

def fallback(conn):
    assert receive_line(conn) == b'{"TLS":{"startTLS":"send"}}\r\n'
    conn.sendall(b'{ "TLS": { "startTLS": "false" } }\r\n')
    assert receive_line(conn) == b'{"hello":1}\r\n'
assert '0:0:' in run('prefer', fallback)

def require(conn):
    receive_line(conn)
    conn.sendall(b'{"TLS":{"startTLS":"false"}}\r\n')
out = run('require', require)
assert '3:0:' in out and '0:0:' not in out, out

def oversized(conn):
    receive_line(conn)
    conn.sendall(b'x' * 131074)
out = run('off', oversized)
assert 'exceeded 131072' in out, out

def unicode_playlist(conn):
    receive_line(conn)
    # Official Python JSON encoding uses surrogate pairs for emoji. This is
    # the complete Syncplay 250-entry/10000-character playlist maximum.
    import json
    payload = json.dumps({'Set': {'playlistChange': {'user': 'official',
                           'files': ['😀' * 40] * 250}}}).encode('ascii')
    assert 120000 < len(payload) < 131072
    conn.sendall(payload + b'\r\n')
out = run('off', unicode_playlist)
assert '1:0:{"Set":' in out and out.count(r'\ud83d\ude00') == 10000 and 'exceeded' not in out, out[:200]

def stalled(conn):
    receive_line(conn)
    time.sleep(3.3)
out = run('prefer', stalled)
assert '0:0:' not in out and int(out.split('disconnect_ms:')[1]) < 250, out

def bulk(conn):
    data = b''
    while data.count(b'\n') < 50:
        block = conn.recv(257)
        assert block, len(data)
        data += block
        time.sleep(.0001)
    assert data == (b'{"payload":"' + b'x' * 16000 + b'"}\r\n') * 50
run('off', bulk, ('127.0.0.1', 'bulk'))
print('PASS: partial reads, multiple lines, CRLF writes, localhost IPv4 fallback, prefer fallback, require rejection, full Unicode playlist, 128KiB line cap, bounded stalled disconnect, 800KB queued writes with slow fragmented reads')
