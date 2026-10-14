"""Self-signed TLS must fail without any plaintext Connected/Hello.

Uses development-only cryptography to create an ephemeral certificate. Does
not modify Windows certificate stores. Run with the repository venv Python.
"""
import datetime
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(hours=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
        .sign(key, hashes.SHA256()))
with tempfile.TemporaryDirectory() as tmp:
    certificate = Path(tmp) / 'cert.pem'
    private = Path(tmp) / 'key.pem'
    certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                        serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, private)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    received = []
    def server():
        conn, _ = listener.accept()
        with conn:
            conn.settimeout(5)
            line = b''
            while not line.endswith(b'\n'):
                line += conn.recv(1)
            received.append(line)
            conn.sendall(b'{"TLS":{"startTLS":"true"}}\r\n')
            try:
                with context.wrap_socket(conn, server_side=True) as secure:
                    received.append(secure.recv(4096))
            except (ssl.SSLError, OSError):
                pass
    worker = threading.Thread(target=server)
    worker.start()
    out = subprocess.run([sys.argv[1], str(listener.getsockname()[1]), 'prefer', 'localhost', 'handshake-only'],
                         capture_output=True, text=True, timeout=10)
    worker.join(6)
    listener.close()
    assert received == [b'{"TLS":{"startTLS":"send"}}\r\n'], received
    assert out.returncode == 0 and '0:1:' not in out.stdout and '0:0:' not in out.stdout, out
    assert 'certificate validation failed' in out.stdout, out.stdout
    print('PASS: self-signed certificate rejected with no plaintext fallback or Connected event')
