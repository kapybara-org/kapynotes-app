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


APP = asc_submit.APP


def version(id_, name, state, app_version_state=None):
    return {"id": id_, "type": "appStoreVersions", "attributes": {
        "versionString": name, "appStoreState": state,
        "appVersionState": app_version_state or state, "releaseType": "AFTER_APPROVAL"}}


def page(*data):
    return 200, {"data": list(data)}


class ScriptedApi:
    """A fake App Store Connect that records every request.

    Routes are (method, fragment, answer). A fragment with "?" matches the
    start of the path; one without matches the path exactly, query aside. An
    answer is (code, body), or a list of them served in turn, the last one
    repeating.
    """

    def __init__(self, routes):
        self.routes = [(method, fragment, list(answer) if isinstance(answer, list) else [answer])
                       for method, fragment, answer in routes]
        self.calls = []

    def __call__(self, request, timeout=None):
        path = request.full_url[len(asc_submit.API):]
        body = json.loads(request.data) if request.data else None
        self.calls.append((request.get_method(), path.split("?")[0], body))
        for method, fragment, answers in self.routes:
            hit = path.startswith(fragment) if "?" in fragment else path.split("?")[0] == fragment
            if method == request.get_method() and hit:
                code, payload = answers.pop(0) if len(answers) > 1 else answers[0]
                raw = json.dumps(payload).encode() if payload is not None else b""
                if code >= 400:
                    raise urllib.error.HTTPError(request.full_url, code, "error", {}, io.BytesIO(raw))
                return io.BytesIO(raw)
        raise AssertionError(f"unexpected request {request.get_method()} {path}")

    def writes(self):
        return [(method, path) for method, path, _ in self.calls if method != "GET"]

    def body(self, method, path):
        return next(body for m, p, body in self.calls if (m, p) == (method, path))


class SwapTest(unittest.TestCase):
    """prepare, submit and status against the 1.35.0-waiting, 1.35.1-new shape."""

    def setUp(self):
        AscSubmitTest.setUp(self)
        self.clock = [0.0]
        self.patch(asc_submit.time, "time", lambda: self.clock[0])
        self.patch(asc_submit.time, "sleep", lambda seconds: self.clock.__setitem__(0, self.clock[0] + seconds))

    patch = AscSubmitTest.patch

    def run_api(self, routes, *modes):
        api = ScriptedApi(routes)
        self.patch(asc_submit.urllib.request, "urlopen", api)
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            try:
                for mode in modes:
                    asc_submit.MODES[mode]()
            except SystemExit as stop:
                return api, stop.code, printed.getvalue()
        return api, None, printed.getvalue()

    def routes(self, *, listing=None, submissions=None, items=None, submission_states=None,
               version_answers=None, rename=(200, {}), find=None):
        old = version("v135", "1.35.0", "WAITING_FOR_REVIEW")
        cancelled = version("v135", "1.35.0", "DEVELOPER_REJECTED")
        renamed = version("v135", "1.35.1", "DEVELOPER_REJECTED")
        return [
            ("GET", "/v1/builds?", page({"id": "b43", "attributes": {"processingState": "VALID"}})),
            ("GET", f"/v1/apps/{APP}/appStoreVersions?filter[versionString]=1.35.1", find or page()),
            ("GET", f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS",
             page(*(listing or [version("v134", "1.34.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION"), old]))),
            ("GET", f"/v1/reviewSubmissions?filter[app]={APP}",
             page(*(submissions or [{"id": "s1", "attributes": {"state": "WAITING_FOR_REVIEW"}}]))),
            ("GET", "/v1/reviewSubmissions/s1/items?",
             page(*(items or [{"id": "i1", "relationships": {
                 "appStoreVersion": {"data": {"type": "appStoreVersions", "id": "v135"}}}}]))),
            ("PATCH", "/v1/reviewSubmissions/s1", (200, {})),
            ("GET", "/v1/reviewSubmissions/s1", submission_states or [
                (200, {"data": {"attributes": {"state": "CANCELING"}}}),
                (200, {"data": {"attributes": {"state": "COMPLETE"}}})]),
            ("GET", "/v1/appStoreVersions/v135", version_answers or [
                (200, {"data": old}), (200, {"data": cancelled}), (200, {"data": renamed})]),
            ("PATCH", "/v1/appStoreVersions/v135", rename),
            ("PATCH", "/v1/appStoreVersions/v135/relationships/build", (204, None)),
            ("GET", "/v1/appStoreVersions/v135/appStoreVersionLocalizations",
             page({"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "Faster search."}})),
            ("PATCH", "/v1/appStoreVersionLocalizations/loc1", (200, {})),
            ("GET", "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets?", page()),
            ("GET", "/v1/appStoreVersions/v135/appStoreVersionPhasedRelease", [
                (200, {"data": {"id": "p1", "attributes": {"phasedReleaseState": "INACTIVE"}}}),
                (404, {"errors": []})]),
            ("DELETE", "/v1/appStoreVersionPhasedReleases/p1", (204, None)),
            ("GET", "/v1/appStoreVersions/v135/appStoreReviewDetail", (404, {"errors": []})),
            ("GET", "/v1/appStoreVersions/v135/build", (200, {"data": {"attributes": {"version": "43"}}})),
            ("POST", "/v1/reviewSubmissions", (201, {"data": {"id": "s2"}})),
            ("POST", "/v1/reviewSubmissionItems", (201, {"data": {"id": "i2"}})),
            ("PATCH", "/v1/reviewSubmissions/s2", (200, {"data": {"attributes": {"state": "WAITING_FOR_REVIEW"}}})),
            ("POST", "/v1/appStoreVersions", (201, {"data": version("v-new", "1.35.1", "PREPARE_FOR_SUBMISSION")})),
        ]

    def test_swap_cancels_renames_prepares_and_submits(self):
        routes = self.routes(find=[page(), page(version("v135", "1.35.1", "DEVELOPER_REJECTED")),
                                   page(version("v135", "1.35.1", "WAITING_FOR_REVIEW"))])
        api, code, printed = self.run_api(routes, "prepare", "submit", "status")
        self.assertIsNone(code, printed)
        self.assertEqual(api.writes(), [
            ("PATCH", "/v1/reviewSubmissions/s1"),
            ("PATCH", "/v1/appStoreVersions/v135"),
            ("PATCH", "/v1/appStoreVersions/v135/relationships/build"),
            ("PATCH", "/v1/appStoreVersionLocalizations/loc1"),
            ("DELETE", "/v1/appStoreVersionPhasedReleases/p1"),
            ("POST", "/v1/reviewSubmissions"),
            ("POST", "/v1/reviewSubmissionItems"),
            ("PATCH", "/v1/reviewSubmissions/s2"),
        ])
        self.assertEqual(api.body("PATCH", "/v1/reviewSubmissions/s1")["data"]["attributes"], {"canceled": True})
        self.assertEqual(api.body("PATCH", "/v1/appStoreVersions/v135")["data"]["attributes"],
                         {"versionString": "1.35.1", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(api.body("PATCH", "/v1/appStoreVersions/v135/relationships/build")["data"]["id"], "b43")
        self.assertEqual(api.body("PATCH", "/v1/appStoreVersionLocalizations/loc1")["data"]["attributes"],
                         {"whatsNew": "Faster search."})
        report = json.loads(printed.strip().splitlines()[-1])
        self.assertEqual(report["state"], ["WAITING_FOR_REVIEW"])
        self.assertEqual(report["build"], "43")
        self.assertTrue(report["whatsNew_matches"])
        self.assertEqual(report["phased"], "none (100% on approval)")

    def test_existing_version_is_prepared_without_a_swap(self):
        routes = self.routes(find=page(version("v135", "1.35.1", "PREPARE_FOR_SUBMISSION")))
        api, code, printed = self.run_api(routes, "prepare")
        self.assertIsNone(code, printed)
        self.assertEqual(api.writes(), [
            ("PATCH", "/v1/appStoreVersions/v135/relationships/build"),
            ("PATCH", "/v1/appStoreVersionLocalizations/loc1"),
            ("DELETE", "/v1/appStoreVersionPhasedReleases/p1"),
        ])
        read = {path for method, path, _ in api.calls}
        self.assertNotIn(f"/v1/apps/{APP}/appStoreVersions?filter[platform]=IOS", read)
        self.assertFalse(any(path.startswith("/v1/reviewSubmissions") for path in read))

    def test_no_earlier_version_creates_the_new_one(self):
        routes = [(m, f.replace("v135", "v-new"), a) for m, f, a in self.routes(
            listing=[version("v134", "1.34.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION")])]
        api, code, printed = self.run_api(routes, "prepare")
        self.assertIsNone(code, printed)
        self.assertEqual(api.writes()[0], ("POST", "/v1/appStoreVersions"))
        self.assertNotIn(("PATCH", "/v1/reviewSubmissions/s1"), api.writes())

    def test_in_review_defers_with_no_writes(self):
        for state in ("IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE"):
            with self.subTest(state=state):
                routes = self.routes(listing=[version("v134", "1.34.0", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION"),
                                              version("v135", "1.35.0", state)])
                api, code, printed = self.run_api(routes, "prepare")
                self.assertEqual(code, asc_submit.DEFERRED_EXIT)
                self.assertEqual(api.writes(), [])
                self.assertIn("Nothing was changed", printed)

    def test_build_not_valid_reads_no_versions_and_writes_nothing(self):
        routes = self.routes()
        routes[0] = ("GET", "/v1/builds?", page({"id": "b43", "attributes": {"processingState": "PROCESSING"}}))
        api, code, _ = self.run_api(routes, "prepare")
        self.assertIn("not VALID", str(code))
        self.assertEqual(api.writes(), [])
        self.assertFalse(any("appStoreVersions" in path for _, path, _ in api.calls))

    def assert_fails_closed(self, routes, message, writes=()):
        api, code, printed = self.run_api(routes, "prepare")
        self.assertIsInstance(code, str, printed)
        self.assertIn(message, code)
        self.assertEqual(api.writes(), list(writes))
        return api

    def test_two_candidate_versions_fail_closed(self):
        self.assert_fails_closed(self.routes(listing=[
            version("v135", "1.35.0", "WAITING_FOR_REVIEW"),
            version("v1341", "1.34.1", "PREPARE_FOR_SUBMISSION")]), "more than one unreleased version")

    def test_submission_with_extra_items_fails_closed(self):
        item = {"relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": "v135"}}}}
        event = {"relationships": {"appStoreVersion": {"data": None}, "appEvent": {"data": {"id": "e1"}}}}
        self.assert_fails_closed(self.routes(items=[item, event]), "holds 2 items")

    def test_other_unexpected_shapes_fail_closed(self):
        waiting = {"id": "s1", "attributes": {"state": "WAITING_FOR_REVIEW"}}
        cases = {
            "two open submissions": (self.routes(submissions=[waiting, {"id": "s0", "attributes": {
                "state": "READY_FOR_REVIEW"}}]), "2 open review submissions"),
            "submission holds another version": (self.routes(items=[{"relationships": {"appStoreVersion": {
                "data": {"type": "appStoreVersions", "id": "v999"}}}}]), "not only version 1.35.0"),
            "unknown state": (self.routes(listing=[version("v135", "1.35.0", "SOMETHING_NEW")]),
                              "does not handle"),
            "states disagree": (self.routes(listing=[version("v135", "1.35.0", "WAITING_FOR_REVIEW",
                                                             "IN_REVIEW")]), "does not handle"),
            "earlier version is editable": (self.routes(listing=[version("v135", "1.35.0", "DEVELOPER_REJECTED")]),
                                            "not WAITING_FOR_REVIEW"),
            "earlier version is not lower": (self.routes(listing=[version("v136", "1.36.0", "WAITING_FOR_REVIEW")]),
                                             "not lower"),
            "listing has a second page": ([
                (m, f, (200, {"data": [], "links": {"next": "x"}}) if "filter[platform]" in f else a)
                for m, f, a in self.routes()], "more than one page"),
        }
        for name, (routes, message) in cases.items():
            with self.subTest(name):
                self.assert_fails_closed(routes, message)

    def test_cancel_that_never_completes_times_out(self):
        api = self.assert_fails_closed(
            self.routes(submission_states=[(200, {"data": {"attributes": {"state": "CANCELING"}}})],
                        version_answers=[(200, {"data": version("v135", "1.35.0", "WAITING_FOR_REVIEW")})]),
            "did not finish within 10 minutes", writes=[("PATCH", "/v1/reviewSubmissions/s1")])
        self.assertGreater(self.clock[0], asc_submit.CANCEL_WAIT_SECONDS)
        self.assertLess(self.clock[0], asc_submit.CANCEL_WAIT_SECONDS + 2 * asc_submit.CANCEL_POLL_SECONDS)

    def test_review_starting_during_the_cancel_fails_closed(self):
        self.assert_fails_closed(
            self.routes(submission_states=[(200, {"data": {"attributes": {"state": "IN_REVIEW"}}})]),
            "went to IN_REVIEW", writes=[("PATCH", "/v1/reviewSubmissions/s1")])

    def test_http_error_mid_swap_stops_before_anything_else(self):
        for code in (409, 500):
            with self.subTest(code=code):
                self.assert_fails_closed(self.routes(rename=(code, {"errors": [{"code": "x"}]})), str(code), writes=[
                    ("PATCH", "/v1/reviewSubmissions/s1"),
                    ("PATCH", "/v1/appStoreVersions/v135"),
                ])

    def test_http_error_on_the_cancel_stops_before_anything_else(self):
        routes = [(m, f, (500, {"errors": []}) if (m, f) == ("PATCH", "/v1/reviewSubmissions/s1") else a)
                  for m, f, a in self.routes()]
        self.assert_fails_closed(routes, "500", writes=[("PATCH", "/v1/reviewSubmissions/s1")])

    def test_status_fails_unless_waiting_for_review(self):
        routes = self.routes(find=page(version("v135", "1.35.1", "PREPARE_FOR_SUBMISSION")))
        routes = [(m, f, (404, {"errors": []}) if f.endswith("PhasedRelease") else a) for m, f, a in routes]
        api, code, _ = self.run_api(routes, "status")
        self.assertIn("does not match", str(code))
        self.assertEqual(api.writes(), [])


if __name__ == "__main__":
    unittest.main()
