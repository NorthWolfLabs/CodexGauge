"""Serve only the two explicitly public rehearsal files, never the key or source."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from urllib.parse import urlsplit

root = Path(sys.argv[1]).resolve()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        name = urlsplit(self.path).path
        if name not in ("/appcast.xml", "/update.zip"):
            self.send_error(404)
            return
        path = root / name[1:]
        if not path.is_file():
            self.send_error(503)
            return
        self.send_response(200)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", "application/xml" if name.endswith(".xml") else "application/zip")
        self.send_header("Content-Length", str(path.stat().st_size))
        self.end_headers()
        with path.open("rb") as source:
            while chunk := source.read(65536):
                self.wfile.write(chunk)

ThreadingHTTPServer(("127.0.0.1", 8876), Handler).serve_forever()
