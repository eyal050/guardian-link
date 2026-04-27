"""Tests for the ML stub HTTP server.

Spins up the real HTTPServer on a random port in a daemon thread — no mocking,
real sockets, real HTTP. The server shuts down after each test class.
"""

import json
import socket
import socketserver
import threading
import unittest

import server


def _start(handler_class):
    class _Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
        allow_reuse_address = True
        daemon_threads = True

    srv = _Server(("127.0.0.1", 0), handler_class)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv, port


def _request(port: int, method: str, path: str, body: bytes = b"") -> tuple[int, str, bytes]:
    """Returns (status_code, headers_str, body_bytes)."""
    with socket.socket() as s:
        s.connect(("127.0.0.1", port))
        raw = (
            f"{method} {path} HTTP/1.0\r\n"
            f"Host: 127.0.0.1\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"\r\n"
        ).encode() + body
        s.sendall(raw)
        resp = b""
        while chunk := s.recv(4096):
            resp += chunk
    headers_raw, _, body_raw = resp.partition(b"\r\n\r\n")
    status = int(headers_raw.split(b"\r\n")[0].split()[1])
    return status, headers_raw.decode(), body_raw


class _SilentHandler(server.Handler):
    def log_message(self, *_):
        pass


class TestClassifyEndpoint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, cls.port = _start(_SilentHandler)

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def test_post_classify_returns_200(self):
        status, _, _ = _request(self.port, "POST", "/classify", b'{"events": []}')
        self.assertEqual(status, 200)

    def test_post_classify_returns_is_crash_true(self):
        _, _, body = _request(self.port, "POST", "/classify", b'{"events": []}')
        self.assertIs(json.loads(body)["is_crash"], True)

    def test_post_classify_returns_confidence_095(self):
        _, _, body = _request(self.port, "POST", "/classify", b'{"events": []}')
        self.assertAlmostEqual(json.loads(body)["confidence"], 0.95, places=5)

    def test_post_classify_accepts_empty_body(self):
        status, _, body = _request(self.port, "POST", "/classify", b"")
        self.assertEqual(status, 200)
        self.assertIn("confidence", json.loads(body))

    def test_post_classify_accepts_any_json_body(self):
        payload = json.dumps([{"x": 1}, {"x": 2}]).encode()
        status, _, _ = _request(self.port, "POST", "/classify", payload)
        self.assertEqual(status, 200)

    def test_classify_response_content_type_is_json(self):
        _, headers, _ = _request(self.port, "POST", "/classify", b'{"events": []}')
        self.assertIn("application/json", headers)


class TestHealthzEndpoint(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv, cls.port = _start(_SilentHandler)

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def test_get_healthz_returns_200(self):
        status, _, _ = _request(self.port, "GET", "/healthz")
        self.assertEqual(status, 200)

    def test_get_healthz_body_contains_ok(self):
        _, _, body = _request(self.port, "GET", "/healthz")
        self.assertIn("ok", body.decode().lower())


if __name__ == "__main__":
    unittest.main()
