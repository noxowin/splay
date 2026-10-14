"""Loopback-only test VOD endpoint with fixture-only query authentication."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--port', type=int, required=True)
args = parser.parse_args()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path != '/fixture.mp4' or parse_qs(url.query).get('test_token') not in (['official-fixture-only'], ['plugin-fixture-only']):
            self.send_error(403)
            return
        size = args.media.stat().st_size
        start, end = 0, size - 1
        requested = self.headers.get('Range')
        if requested:
            try:
                left, right = requested.removeprefix('bytes=').split('-', 1)
                start = int(left)
                end = min(int(right), size - 1) if right else size - 1
                if not 0 <= start <= end < size:
                    raise ValueError()
            except ValueError:
                self.send_error(416)
                return
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            with args.media.open('rb') as source:
                source.seek(start)
                remaining = end - start + 1
                while remaining:
                    chunk = source.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
