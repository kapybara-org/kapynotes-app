import http.server
import io
import os
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout

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


class PromoteTest(unittest.TestCase):
    """promote and upload against a recorded stand-in for the Play API."""

    def setUp(self):
        self.calls = []

        def fake_call(method, url, *, body=None, data=None, content_type=None, soft=False):
            self.calls.append((method, url, body))
            if method == "POST" and url.endswith("/edits"):
                return {"id": "edit"}
            if method == "GET" and url.endswith("/tracks"):
                return {"tracks": [{"track": "internal", "releases": [{"versionCodes": ["43"]}]}]}
            return {}

        self.patch("call", fake_call)

    def patch(self, name, value):
        original = getattr(upload_play, name)
        setattr(upload_play, name, value)
        self.addCleanup(setattr, upload_play, name, original)

    def notes_file(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def commits(self):
        return [url for method, url, _ in self.calls if url.endswith(":commit") or ":commit?" in url]

    def puts(self):
        return [body for method, _, body in self.calls if method == "PUT"]

    def test_promote_takes_notes_from_the_file(self):
        upload_play.promote("43", "production", 1.0, self.notes_file("Faster search.\n"))
        [body] = self.puts()
        release = body["releases"][0]
        self.assertEqual(release["releaseNotes"], [{"language": "en-US", "text": "Faster search."}])
        self.assertEqual(release["status"], "completed")
        self.assertNotIn("userFraction", release)

    def test_promote_commit_leaves_a_review_in_progress_alone(self):
        upload_play.promote("43", "production", 1.0, self.notes_file("Notes"))
        self.assertEqual(self.commits(), [
            f"{upload_play.API}/applications/{upload_play.PACKAGE_NAME}/edits/edit:commit"
            "?changesInReviewBehavior=ERROR_IF_IN_REVIEW",
        ])

    def test_upload_commit_leaves_a_review_in_progress_alone(self):
        self.patch("upload_bundle", lambda edit_id, bundle: {"versionCode": 43})
        upload_play.upload("unused.aab", "internal")
        self.assertEqual(len(self.commits()), 1)
        self.assertTrue(self.commits()[0].endswith(":commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW"))

    def refuse_commit(self, message):
        recorded = upload_play.call

        def fake_call(method, url, *, body=None, data=None, content_type=None, soft=False):
            if ":commit" in url:
                self.calls.append((method, url, body))
                self.assertTrue(soft)
                raise upload_play.PlayError(message)
            return recorded(method, url, body=body, data=data, content_type=content_type, soft=soft)

        self.patch("call", fake_call)
        self.patch("upload_bundle", lambda edit_id, bundle: {"versionCode": 47})

    def test_upload_refused_for_a_foreground_service_explains_the_console_upload(self):
        self.refuse_commit("You must let us know whether your app uses any Foreground Service permissions.")
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            upload_play.upload("unused.aab", "internal")
        self.assertIn("Foreground Service permissions", err.getvalue())
        self.assertIn("version code 47 is still free", err.getvalue())
        self.assertIn("Testing -> Internal testing", err.getvalue())

    def test_upload_refused_for_another_reason_says_only_that(self):
        self.refuse_commit("Changes are currently in review.")
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            upload_play.upload("unused.aab", "internal")
        self.assertIn("Changes are currently in review.", err.getvalue())
        self.assertNotIn("declaration", err.getvalue())

    def test_empty_notes_file_is_refused(self):
        with self.assertRaises(SystemExit):
            upload_play.promote("43", "production", 1.0, self.notes_file("  \n"))
        self.assertEqual(self.puts(), [])
        self.assertEqual(self.commits(), [])

    def test_notes_over_plays_limit_are_refused(self):
        too_long = "x" * (upload_play.RELEASE_NOTES_LIMIT + 1)
        with self.assertRaises(SystemExit):
            upload_play.promote("43", "production", 1.0, self.notes_file(too_long))
        self.assertEqual(self.puts(), [])

    def test_missing_notes_file_is_refused(self):
        with self.assertRaises(SystemExit):
            upload_play.promote("43", "production", 1.0, "/nonexistent/notes.txt")
        self.assertEqual(self.puts(), [])

    def test_main_passes_the_notes_file_to_promote(self):
        seen = []
        self.patch("promote", lambda *args: seen.append(args))
        original = sys.argv
        sys.argv = ["upload_play.py", "promote", "--track", "production", "--rollout", "1",
                    "--version-code", "43", "--notes-file", "metadata/play.txt"]
        self.addCleanup(setattr, sys, "argv", original)
        upload_play.main()
        self.assertEqual(seen, [("43", "production", 1.0, "metadata/play.txt", None, False)])

    def test_main_passes_from_track_and_validate_only_to_promote(self):
        seen = []
        self.patch("promote", lambda *args: seen.append(args))
        original = sys.argv
        sys.argv = ["upload_play.py", "promote", "--track", "production", "--rollout", "1",
                    "--version-code", "48", "--notes-file", "n.txt", "--from-track", "internal",
                    "--validate-only"]
        self.addCleanup(setattr, sys, "argv", original)
        upload_play.main()
        self.assertEqual(seen, [("48", "production", 1.0, "n.txt", "internal", True)])

    def tracks(self, *entries):
        recorded = upload_play.call

        def fake_call(method, url, *, body=None, data=None, content_type=None, soft=False):
            if method == "GET" and url.endswith("/tracks"):
                self.calls.append((method, url, body))
                return {"tracks": [{"track": name, "releases": [{"versionCodes": codes, "status": status}]}
                                   for name, codes, status in entries]}
            return recorded(method, url, body=body, data=data, content_type=content_type, soft=soft)

        self.patch("call", fake_call)

    def deletes(self):
        return [url for method, url, _ in self.calls if method == "DELETE"]

    def test_promote_from_internal_refuses_a_code_not_on_internal(self):
        self.tracks(("production", ["48"], "completed"), ("internal", ["47"], "completed"))
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            upload_play.promote("48", "production", 1.0, self.notes_file("Notes"), "internal")
        self.assertIn("not on the internal track", err.getvalue())
        self.assertEqual(self.puts(), [])
        self.assertEqual(self.commits(), [])
        self.assertEqual(len(self.deletes()), 1)

    def test_promote_of_a_code_already_live_changes_nothing(self):
        self.tracks(("internal", ["48"], "completed"), ("production", ["48"], "completed"))
        upload_play.promote("48", "production", 1.0, self.notes_file("Notes"), "internal")
        self.assertEqual(self.puts(), [])
        self.assertEqual(self.commits(), [])
        self.assertEqual(len(self.deletes()), 1)

    def test_validate_only_asks_play_to_validate_and_never_commits(self):
        self.tracks(("internal", ["48"], "completed"), ("production", ["47"], "completed"))
        with redirect_stdout(io.StringIO()) as out:
            upload_play.promote("48", "production", 1.0, self.notes_file("Notes"), "internal", True)
        self.assertIn("nothing was committed", out.getvalue())
        self.assertNotIn("is now on", out.getvalue())
        [body] = self.puts()
        self.assertEqual(body["releases"][0]["versionCodes"], ["48"])
        self.assertEqual(body["releases"][0]["status"], "completed")
        self.assertEqual(self.commits(), [])
        validates = [url for _, url, _ in self.calls if url.endswith(":validate")]
        self.assertEqual(validates, [f"{upload_play.API}/applications/{upload_play.PACKAGE_NAME}/edits/edit:validate"])
        self.assertEqual(len(self.deletes()), 1)

    def test_validate_only_still_checks_a_code_already_live(self):
        self.tracks(("internal", ["48"], "completed"), ("production", ["48"], "completed"))
        upload_play.promote("48", "production", 1.0, self.notes_file("Notes"), "internal", True)
        self.assertEqual(len(self.puts()), 1)
        self.assertEqual(self.commits(), [])

    def test_promote_while_changes_are_in_review_says_so_plainly(self):
        self.tracks(("internal", ["48"], "completed"), ("production", ["47"], "completed"))
        recorded = upload_play.call

        def fake_call(method, url, *, body=None, data=None, content_type=None, soft=False):
            if ":commit" in url:
                self.calls.append((method, url, body))
                raise upload_play.PlayError(
                    "You already have changes in review. Cancel this review or wait for it "
                    "to complete before you try again.")
            return recorded(method, url, body=body, data=data, content_type=content_type, soft=soft)

        self.patch("call", fake_call)
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            upload_play.promote("48", "production", 1.0, self.notes_file("Notes"), "internal")
        self.assertIn("Google is still reviewing an earlier change", err.getvalue())
        self.assertIn("nothing was changed", err.getvalue())
        self.assertEqual(len(self.puts()), 1)
        self.assertEqual(len(self.deletes()), 1)


if __name__ == "__main__":
    unittest.main()
