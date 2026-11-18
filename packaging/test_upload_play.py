import http.server
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upload_play


class StubUploadServer(http.server.ThreadingHTTPServer):
    """A resumable-upload endpoint that drops chunks on request."""

    def __init__(self, expected, drop):
        super().__init__(("127.0.0.1", 0), StubUploadHandler)
        self.expected = expected
        self.drop = drop
        self.held = bytearray()
        self.puts = 0


class StubUploadHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", headers=()):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        host, port = self.server.server_address
        self.reply(200, headers=[("Location", f"http://{host}:{port}/session")])

    def do_PUT(self):
        server = self.server
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if body:
            server.puts += 1
            if server.drop(server.puts):
                self.close_connection = True
                self.connection.close()
                return
            start = int(self.headers["Content-Range"].split()[1].split("-")[0])
            if start != len(server.held):
                self.reply(400)
                return
            server.held.extend(body)
        if len(server.held) == len(server.expected):
            self.reply(200, b'{"versionCode": 38}')
        elif server.held:
            self.reply(308, headers=[("Range", f"bytes=0-{len(server.held) - 1}")])
        else:
            self.reply(308)


class UploadBundleTest(unittest.TestCase):
    def setUp(self):
        self.data = os.urandom(5 * 64 * 1024 + 123)
        handle = tempfile.NamedTemporaryFile(delete=False)
        handle.write(self.data)
        handle.close()
        self.bundle = handle.name
        self.addCleanup(os.unlink, self.bundle)
        self.sleeps = []
        self.patch("UPLOAD_CHUNK", 64 * 1024)
        self.patch("TOKEN", "token")
        self.patch_sleep()

    def patch(self, name, value):
        original = getattr(upload_play, name)
        setattr(upload_play, name, value)
        self.addCleanup(setattr, upload_play, name, original)

    def patch_sleep(self):
        original = upload_play.time.sleep
        upload_play.time.sleep = self.sleeps.append
        self.addCleanup(setattr, upload_play.time, "sleep", original)

    def serve(self, drop):
        server = StubUploadServer(self.data, drop)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        host, port = server.server_address
        self.patch("UPLOAD_API", f"http://{host}:{port}")
        return server

    def test_completes_after_a_dropped_chunk(self):
        server = self.serve(lambda put: put == 2)
        result = upload_play.upload_bundle("edit", self.bundle)
        self.assertEqual(result, {"versionCode": 38})
        self.assertEqual(bytes(server.held), self.data)

    def test_fails_when_every_chunk_drops(self):
        server = self.serve(lambda put: True)
        with self.assertRaises(SystemExit) as raised:
            upload_play.upload_bundle("edit", self.bundle)
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(server.puts, upload_play.UPLOAD_STALL_LIMIT)
        self.assertEqual(self.sleeps, [5, 10, 15, 20, 25])

    def test_a_stall_after_progress_still_fails(self):
        server = self.serve(lambda put: put > 2)
        with self.assertRaises(SystemExit):
            upload_play.upload_bundle("edit", self.bundle)
        self.assertEqual(len(server.held), 2 * 64 * 1024)
        self.assertEqual(server.puts, 2 + upload_play.UPLOAD_STALL_LIMIT)


if __name__ == "__main__":
    unittest.main()
