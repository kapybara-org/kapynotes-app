import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_submit


class FakeApi:
    """Answers urlopen by the first route whose fragment is in the URL."""

    def __init__(self, routes):
        self.routes = routes

    def __call__(self, request, timeout=None):
        for fragment, answer in self.routes:
            if fragment in request.full_url:
                if isinstance(answer, BaseException):
                    raise answer
                code, body = answer
                if code >= 400:
                    raise urllib.error.HTTPError(
                        request.full_url, code, "error", {}, io.BytesIO(json.dumps(body).encode()))
                return io.BytesIO(json.dumps(body).encode())
        raise AssertionError(f"unexpected request {request.full_url}")


class AscSubmitTest(unittest.TestCase):
    def setUp(self):
        self.patch(asc_submit, "token", lambda: "token")
        notes = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8")
        notes.write("Faster search.\n")
        notes.close()
        self.addCleanup(os.unlink, notes.name)
        for name, value in (("VER", "1.35.1"), ("BUILD", "43"), ("NOTES_FILE", notes.name)):
            self.addCleanup(os.environ.pop, name, None)
            os.environ[name] = value

    def patch(self, owner, name, value):
        original = getattr(owner, name)
        setattr(owner, name, value)
        self.addCleanup(setattr, owner, name, original)

    def serve(self, *routes):
        self.patch(asc_submit.urllib.request, "urlopen", FakeApi(list(routes)))

    def test_404_means_absent(self):
        self.serve(("/phased", (404, {"errors": []})))
        self.assertIsNone(asc_submit.optional("/v1/x/phased"))

    def test_200_returns_the_data(self):
        self.serve(("/phased", (200, {"data": {"id": "p1"}})))
        self.assertEqual(asc_submit.optional("/v1/x/phased"), {"id": "p1"})

    def test_other_http_errors_stop_the_run(self):
        for code in (401, 403, 429, 500, 503):
            with self.subTest(code=code):
                self.serve(("/phased", (code, {"errors": []})))
                with self.assertRaises(SystemExit) as raised:
                    asc_submit.optional("/v1/x/phased")
                self.assertIn(str(code), str(raised.exception.code))

    def test_network_errors_stop_the_run(self):
        self.serve(("/phased", urllib.error.URLError("connection reset")))
        with self.assertRaises(urllib.error.URLError):
            asc_submit.optional("/v1/x/phased")

    def test_status_fails_when_the_phased_check_cannot_be_made(self):
        version = {"id": "v1", "attributes": {"appStoreState": "WAITING_FOR_REVIEW",
                                              "releaseType": "AFTER_APPROVAL"}}
        self.serve(
            ("/appStoreVersions?", (200, {"data": [version]})),
            ("/v1/appStoreVersions/v1/build", (200, {"data": {"attributes": {"version": "43"}}})),
            ("/appStoreVersionLocalizations", (200, {"data": [{"attributes": {"whatsNew": "Faster search."}}]})),
            ("/appStoreVersionPhasedRelease", (500, {"errors": []})),
        )
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed), self.assertRaises(SystemExit):
            asc_submit.status()
        self.assertNotIn("phased", printed.getvalue())

    def test_status_passes_when_there_is_no_phased_release(self):
        version = {"id": "v1", "attributes": {"appStoreState": "WAITING_FOR_REVIEW",
                                              "releaseType": "AFTER_APPROVAL"}}
        self.serve(
            ("/appStoreVersions?", (200, {"data": [version]})),
            ("/v1/appStoreVersions/v1/build", (200, {"data": {"attributes": {"version": "43"}}})),
            ("/appStoreVersionLocalizations", (200, {"data": [{"attributes": {"whatsNew": "Faster search."}}]})),
            ("/appStoreVersionPhasedRelease", (404, {"errors": []})),
        )
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            asc_submit.status()
        self.assertEqual(json.loads(printed.getvalue())["phased"], "none (100% on approval)")


if __name__ == "__main__":
    unittest.main()
