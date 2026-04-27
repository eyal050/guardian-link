"""Minimal ML stub HTTP server.

POST /classify  → {"is_crash": true, "confidence": 0.95}
GET  /healthz   → 200 ok
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

_RESPONSE = json.dumps({"is_crash": True, "confidence": 0.95}).encode()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/classify":
            content_len = int(self.headers.get("Content-Length", 0))
            self.rfile.read(content_len)  # consume body, ignore contents
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(_RESPONSE)))
            self.end_headers()
            self.wfile.write(_RESPONSE)
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        print(f"[ml-stub] {fmt % args}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8080"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"[ml-stub] listening on :{port}", flush=True)
    server.serve_forever()
