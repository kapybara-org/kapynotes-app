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
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"}
OPEN = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES", "CANCELING", "COMPLETING"}


class FakeAsc:
    """A small in-memory App Store Connect that records every request.

    It starts where the store is today: 1.34.0 on sale, 1.35.0 (build 42)
    waiting for review in submission s1, and build 43 processed. Writes change
    its state, and a cancelled submission completes after cancel_polls reads
    (never, when None), leaving its version DEVELOPER_REJECTED.
    """

    def __init__(self):
        self.builds = {"b41": "41", "b42": "42", "b43": "43"}
        self.processing = "VALID"
        self.versions = {
            "v134": {"versionString": "1.34.0", "state": ("READY_FOR_SALE", "READY_FOR_DISTRIBUTION"),
                     "releaseType": "AFTER_APPROVAL", "build": "b41"},
            "v135": {"versionString": "1.35.0", "state": ("WAITING_FOR_REVIEW", "WAITING_FOR_REVIEW"),
                     "releaseType": "AFTER_APPROVAL", "build": "b42"},
        }
        self.localizations = {
            "v134": {"l134": ["en-US", "1.34.0 notes"]},
            "v135": {"loc1": ["en-US", "1.35.0 notes"], "loc2": ["en-GB", "1.35.0 notes, GB"]},
        }
        self.phased = {}
        self.submissions = {"s1": {"state": "WAITING_FOR_REVIEW", "items": ["v135"], "polls": 0}}
        self.cancel_polls = 1
        self.cancel_ends_in = "COMPLETE"
        self.failures = {}
        self.calls = []

    def fail(self, method, path, code, skip=0, times=1):
        self.failures[(method, path)] = [None] * skip + [code] * times

    def set_state(self, version_id, state):
        self.versions[version_id]["state"] = (state, state)

    def version(self, version_id):
        version = self.versions[version_id]
        return {"id": version_id, "type": "appStoreVersions", "attributes": {
            "versionString": version["versionString"], "appStoreState": version["state"][0],
            "appVersionState": version["state"][1], "releaseType": version["releaseType"]}}

    def editable(self, version_id):
        if not set(self.versions[version_id]["state"]) <= EDITABLE:
            raise Reply(409, {"errors": [{"code": "ENTITY_ERROR.STATE"}]})

    def __call__(self, request, timeout=None):
        method, url = request.get_method(), request.full_url[len(asc_submit.API):]
        path, _, query = url.partition("?")
        body = json.loads(request.data) if request.data else None
        self.calls.append((method, path, body))
        pending = self.failures.get((method, path))
        try:
            if pending:
                code = pending.pop(0)
                if code:
                    raise Reply(code, {"errors": [{"code": "INJECTED"}]})
            raise Reply(*self.answer(method, path, query, body))
        except Reply as reply:
            raw = json.dumps(reply.body).encode() if reply.body is not None else b""
            if reply.code >= 400:
                raise urllib.error.HTTPError(request.full_url, reply.code, "error", {}, io.BytesIO(raw))
            return io.BytesIO(raw)

    def answer(self, method, path, query, body):
        parts = path.strip("/").split("/")[1:]
        if path == "/v1/builds":
            number = query.split("filter[version]=")[1].split("&")[0]
            return 200, {"data": [{"id": b, "attributes": {"processingState": self.processing, "version": n}}
                                  for b, n in self.builds.items() if n == number]}
        if path == f"/v1/apps/{APP}/appStoreVersions":
            wanted = query.split("filter[versionString]=")[1].split("&")[0] if "versionString" in query else None
            return 200, {"data": [self.version(v) for v, data in self.versions.items()
                                  if wanted in (None, data["versionString"])]}
        if path == "/v1/appStoreVersions" and method == "POST":
            self.versions["v-new"] = {"versionString": body["data"]["attributes"]["versionString"],
                                      "state": ("PREPARE_FOR_SUBMISSION",) * 2,
                                      "releaseType": "AFTER_APPROVAL", "build": None}
            self.localizations["v-new"] = {"l-new": ["en-US", ""]}
            return 201, {"data": self.version("v-new")}
        if parts[0] == "appStoreVersions":
            version_id = parts[1]
            tail = parts[2:]
            if not tail and method == "GET":
                return 200, {"data": self.version(version_id)}
            if not tail and method == "PATCH":
                self.editable(version_id)
                self.versions[version_id].update(body["data"]["attributes"])
                return 200, {"data": self.version(version_id)}
            if tail == ["build"]:
                build = self.versions[version_id]["build"]
                if not build:
                    return 404, {"errors": []}
                return 200, {"data": {"id": build, "attributes": {"version": self.builds[build]}}}
            if tail == ["relationships", "build"]:
                self.editable(version_id)
                self.versions[version_id]["build"] = body["data"]["id"]
                return 204, None
            if tail == ["appStoreVersionLocalizations"]:
                return 200, {"data": [{"id": l, "attributes": {"locale": locale, "whatsNew": text}}
                                      for l, (locale, text) in self.localizations[version_id].items()]}
            if tail == ["appStoreVersionPhasedRelease"]:
                if version_id not in self.phased:
                    return 404, {"errors": []}
                return 200, {"data": {"id": self.phased[version_id], "attributes": {"phasedReleaseState": "INACTIVE"}}}
            if tail == ["appStoreReviewDetail"]:
                return 404, {"errors": []}
        if parts[0] == "appStoreVersionLocalizations":
            if parts[2:] == ["appScreenshotSets"]:
                return 200, {"data": []}
            for version_id, entries in self.localizations.items():
                if parts[1] in entries:
                    self.editable(version_id)
                    entries[parts[1]][1] = body["data"]["attributes"]["whatsNew"]
                    return 200, {}
        if parts[0] == "appStoreVersionPhasedReleases" and method == "DELETE":
            self.phased = {v: p for v, p in self.phased.items() if p != parts[1]}
            return 204, None
        if path == "/v1/reviewSubmissions" and method == "GET":
            return 200, {"data": [{"id": s, "attributes": {"state": data["state"]}}
                                  for s, data in self.submissions.items() if data["state"] in OPEN]}
        if path == "/v1/reviewSubmissions" and method == "POST":
            submission_id = f"s{len(self.submissions) + 1}"
            self.submissions[submission_id] = {"state": "READY_FOR_REVIEW", "items": [], "polls": 0}
            return 201, {"data": {"id": submission_id}}
        if path == "/v1/reviewSubmissionItems":
            submission_id = body["data"]["relationships"]["reviewSubmission"]["data"]["id"]
            version_id = body["data"]["relationships"]["appStoreVersion"]["data"]["id"]
            if any(version_id in s["items"] and s["state"] in OPEN for s in self.submissions.values()):
                return 409, {"errors": [{"code": "ITEM_PART_OF_ANOTHER_SUBMISSION"}]}
            self.submissions[submission_id]["items"].append(version_id)
            return 201, {"data": {"id": "item"}}
        if parts[0] == "reviewSubmissions":
            submission = self.submissions[parts[1]]
            if parts[2:] == ["items"]:
                return 200, {"data": [{"id": f"i{n}", "relationships": {"appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": v} if v else None}}}
                    for n, v in enumerate(submission["items"])]}
            if method == "PATCH":
                attributes = body["data"]["attributes"]
                if attributes.get("canceled"):
                    submission["state"] = "CANCELING"
                if attributes.get("submitted"):
                    submission["state"] = "WAITING_FOR_REVIEW"
                    for version_id in submission["items"]:
                        self.set_state(version_id, "WAITING_FOR_REVIEW")
                return 200, {"data": {"attributes": {"state": submission["state"]}}}
            if submission["state"] == "CANCELING":
                submission["polls"] += 1
                if self.cancel_polls is not None and submission["polls"] > self.cancel_polls:
                    submission["state"] = self.cancel_ends_in
                    for version_id in submission["items"]:
                        self.set_state(version_id, "DEVELOPER_REJECTED" if self.cancel_ends_in == "COMPLETE"
                                       else self.cancel_ends_in)
            return 200, {"data": {"attributes": {"state": submission["state"]}}}
        raise AssertionError(f"unexpected request {method} {path}")

    def writes(self):
        return [(method, path) for method, path, _ in self.calls if method != "GET"]

    def written(self, method, path, index=0):
        return [body for m, p, body in self.calls if (m, p) == (method, path)][index]["data"]

    def notes(self, version_id):
        return {l: text for l, (_, text) in self.localizations[version_id].items()}


class Reply(Exception):
    def __init__(self, code, body):
        self.code, self.body = code, body


CANCEL = ("PATCH", "/v1/reviewSubmissions/s1")
RENAME = ("PATCH", "/v1/appStoreVersions/v135")
BUILD = ("PATCH", "/v1/appStoreVersions/v135/relationships/build")
LOC1 = ("PATCH", "/v1/appStoreVersionLocalizations/loc1")
LOC2 = ("PATCH", "/v1/appStoreVersionLocalizations/loc2")
NEW_SUBMISSION = ("POST", "/v1/reviewSubmissions")
ITEM = ("POST", "/v1/reviewSubmissionItems")
OLD_NOTES = {"loc1": "1.35.0 notes", "loc2": "1.35.0 notes, GB"}


def sent(submission_id):
    return ("PATCH", f"/v1/reviewSubmissions/{submission_id}")


class SwapTest(unittest.TestCase):
    """prepare, submit and status against today's shape: 1.35.0 waiting, 1.35.1 new."""

    def setUp(self):
        AscSubmitTest.setUp(self)
        self.clock = [0.0]
        self.patch(asc_submit.time, "time", lambda: self.clock[0])
        self.patch(asc_submit.time, "sleep", lambda seconds: self.clock.__setitem__(0, self.clock[0] + seconds))
        self.asc = FakeAsc()
        self.patch(asc_submit.urllib.request, "urlopen", self.asc)

    patch = AscSubmitTest.patch

    def run_modes(self, *modes):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            try:
                for mode in modes:
                    asc_submit.MODES[mode]()
            except SystemExit as stop:
                return stop.code, printed.getvalue()
        return None, printed.getvalue()

    def assert_untouched(self):
        self.assertEqual(self.asc.versions["v135"]["versionString"], "1.35.0")
        self.assertEqual(self.asc.versions["v135"]["build"], "b42")
        self.assertEqual(self.asc.notes("v135"), OLD_NOTES)

    def assert_resubmitted_as_it_was(self, code):
        self.assertIsInstance(code, str)
        self.assertTrue(code.startswith("swap failed: "), code)
        self.assertTrue(code.endswith("; 1.35.0 resubmitted for review as it was"), code)
        self.assert_untouched()
        self.assertEqual(self.asc.versions["v135"]["state"], ("WAITING_FOR_REVIEW",) * 2)
        self.assertEqual(self.asc.versions["v135"]["releaseType"], "AFTER_APPROVAL")
        self.assertEqual(self.asc.phased, {})

    def test_swap_cancels_renames_prepares_and_submits(self):
        code, printed = self.run_modes("prepare", "submit", "status")
        self.assertIsNone(code, printed)
        self.assertEqual(self.asc.writes(), [CANCEL, RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM, sent("s2")])
        self.assertEqual(self.asc.written(*CANCEL)["attributes"], {"canceled": True})
        self.assertEqual(self.asc.written(*RENAME)["attributes"],
                         {"versionString": "1.35.1", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(self.asc.written(*BUILD)["id"], "b43")
        self.assertEqual(self.asc.notes("v135"), {"loc1": "Faster search.", "loc2": "Faster search."})
        self.assertEqual(self.asc.versions["v135"]["state"], ("WAITING_FOR_REVIEW",) * 2)
        self.assertIn("already waiting for review", printed)
        report = json.loads(printed.strip().splitlines()[-1])
        self.assertEqual(report["state"], ["WAITING_FOR_REVIEW"])
        self.assertEqual(report["build"], "43")
        self.assertTrue(report["whatsNew_matches"])
        self.assertEqual(report["phased"], "none (100% on approval)")

    def test_existing_version_is_prepared_without_a_swap(self):
        self.asc.versions["v135"].update(versionString="1.35.1", state=("PREPARE_FOR_SUBMISSION",) * 2)
        self.asc.phased["v135"] = "p1"
        code, printed = self.run_modes("prepare")
        self.assertIsNone(code, printed)
        self.assertEqual(self.asc.writes(), [BUILD, LOC1, LOC2, ("DELETE", "/v1/appStoreVersionPhasedReleases/p1")])
        self.assertFalse(any(path.startswith("/v1/reviewSubmissions") for _, path, _ in self.asc.calls))
        self.assertEqual(sum(path == f"/v1/apps/{APP}/appStoreVersions" for _, path, _ in self.asc.calls), 1)

    def test_no_earlier_version_creates_the_new_one(self):
        del self.asc.versions["v135"]
        self.asc.submissions.clear()
        code, printed = self.run_modes("prepare", "submit")
        self.assertIsNone(code, printed)
        self.assertEqual(self.asc.writes(), [
            ("POST", "/v1/appStoreVersions"), ("PATCH", "/v1/appStoreVersions/v-new/relationships/build"),
            ("PATCH", "/v1/appStoreVersionLocalizations/l-new"), NEW_SUBMISSION, ITEM, sent("s1")])

    def test_in_review_defers_with_no_writes(self):
        for state in ("IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE"):
            with self.subTest(state=state):
                self.asc = FakeAsc()
                self.patch(asc_submit.urllib.request, "urlopen", self.asc)
                self.asc.set_state("v135", state)
                code, printed = self.run_modes("prepare")
                self.assertEqual(code, asc_submit.DEFERRED_EXIT)
                self.assertEqual(self.asc.writes(), [])
                self.assertIn("Nothing was changed", printed)

    def test_build_not_valid_reads_no_versions_and_writes_nothing(self):
        self.asc.processing = "PROCESSING"
        code, _ = self.run_modes("prepare")
        self.assertIn("not VALID", str(code))
        self.assertEqual(self.asc.writes(), [])
        self.assertFalse(any("appStoreVersions" in path for _, path, _ in self.asc.calls))

    def assert_fails_closed(self, message):
        code, printed = self.run_modes("prepare")
        self.assertIsInstance(code, str, printed)
        self.assertIn(message, code)
        self.assertEqual(self.asc.writes(), [])
        self.assert_untouched()

    def test_two_candidate_versions_fail_closed(self):
        self.asc.versions["v1341"] = {"versionString": "1.34.1", "state": ("PREPARE_FOR_SUBMISSION",) * 2,
                                      "releaseType": "AFTER_APPROVAL", "build": None}
        self.assert_fails_closed("more than one unreleased version")

    def test_submission_with_extra_items_fails_closed(self):
        self.asc.submissions["s1"]["items"].append(None)
        self.assert_fails_closed("holds 2 items")

    def test_other_unexpected_shapes_fail_closed(self):
        def two_open(asc):
            asc.submissions["s0"] = {"state": "READY_FOR_REVIEW", "items": [], "polls": 0}

        def other_version(asc):
            asc.submissions["s1"]["items"] = ["v134"]

        def unknown(asc):
            asc.set_state("v135", "SOMETHING_NEW")

        def disagree(asc):
            asc.versions["v135"]["state"] = ("WAITING_FOR_REVIEW", "IN_REVIEW")

        def editable(asc):
            asc.set_state("v135", "DEVELOPER_REJECTED")

        def not_lower(asc):
            asc.versions["v135"]["versionString"] = "1.36.0"

        def phased(asc):
            asc.phased["v135"] = "p9"

        def no_build(asc):
            asc.versions["v135"]["build"] = None

        cases = [(two_open, "2 open review submissions"), (other_version, "not only version 1.35.0"),
                 (unknown, "does not handle"), (disagree, "does not handle"),
                 (editable, "not WAITING_FOR_REVIEW"), (not_lower, "not lower"),
                 (phased, "has a phased release"), (no_build, "has no build")]
        for shape, message in cases:
            with self.subTest(shape.__name__):
                self.asc = FakeAsc()
                self.patch(asc_submit.urllib.request, "urlopen", self.asc)
                shape(self.asc)
                code, printed = self.run_modes("prepare")
                self.assertIsInstance(code, str, printed)
                self.assertIn(message, code)
                self.assertEqual(self.asc.writes(), [])

    def test_listing_with_a_second_page_fails_closed(self):
        original = self.asc.answer

        def paged(method, path, query, body):
            code, payload = original(method, path, query, body)
            if path == f"/v1/apps/{APP}/appStoreVersions" and "versionString" not in query:
                payload["links"] = {"next": "page-2"}
            return code, payload

        self.asc.answer = paged
        self.assert_fails_closed("more than one page")

    def test_failure_after_the_rename_restores_name_build_and_notes(self):
        self.asc.fail(*LOC2, 409)
        code, printed = self.run_modes("prepare")
        self.assertEqual(self.asc.writes(), [
            CANCEL, RENAME, BUILD, LOC1, LOC2,
            RENAME, BUILD, LOC1,
            NEW_SUBMISSION, ITEM, sent("s2"),
        ])
        self.assertEqual(self.asc.written(*RENAME, index=1)["attributes"],
                         {"versionString": "1.35.0", "releaseType": "AFTER_APPROVAL"})
        self.assertEqual(self.asc.written(*BUILD, index=1)["id"], "b42")
        self.assertEqual(self.asc.written(*LOC1, index=1)["attributes"], {"whatsNew": "1.35.0 notes"})
        self.assertIn("409", code)
        self.assert_resubmitted_as_it_was(code)
        self.assertEqual(self.asc.submissions["s2"]["items"], ["v135"])

    def test_build_attach_409_restores_only_what_changed(self):
        self.asc.fail(*BUILD, 409)
        code, printed = self.run_modes("prepare")
        self.assertEqual(self.asc.writes(), [CANCEL, RENAME, BUILD, RENAME, NEW_SUBMISSION, ITEM, sent("s2")])
        self.assert_resubmitted_as_it_was(code)

    def test_failure_on_the_new_submission_rolls_back_fully(self):
        cases = {
            "adding the item": (ITEM, [CANCEL, RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM,
                                       RENAME, BUILD, LOC1, LOC2, ITEM, sent("s2")]),
            "sending it": (sent("s2"), [CANCEL, RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM, sent("s2"),
                                        RENAME, BUILD, LOC1, LOC2, sent("s2")]),
            "creating it": (NEW_SUBMISSION, [CANCEL, RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION,
                                             RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM, sent("s2")]),
        }
        for name, (failing, writes) in cases.items():
            with self.subTest(name):
                self.asc = FakeAsc()
                self.patch(asc_submit.urllib.request, "urlopen", self.asc)
                self.asc.fail(*failing, 500)
                code, printed = self.run_modes("prepare")
                self.assertEqual(self.asc.writes(), writes)
                self.assertIn("500", code)
                self.assert_resubmitted_as_it_was(code)

    def test_failed_read_back_withdraws_the_new_submission_and_rolls_back(self):
        self.asc.fail("GET", "/v1/appStoreVersions/v135/build", 500, skip=1)
        code, printed = self.run_modes("prepare")
        self.assertEqual(self.asc.writes(), [
            CANCEL, RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM, sent("s2"),
            sent("s2"), RENAME, BUILD, LOC1, LOC2, NEW_SUBMISSION, ITEM, sent("s3"),
        ])
        self.assertEqual(self.asc.written(*sent("s2"), index=1)["attributes"], {"canceled": True})
        self.assertEqual(self.asc.submissions["s2"]["state"], "COMPLETE")
        self.assert_resubmitted_as_it_was(code)

    def test_cancel_that_never_completes_fails_loudly_without_restoring(self):
        self.asc.cancel_polls = None
        code, printed = self.run_modes("prepare")
        self.assertEqual(code, asc_submit.ROLLBACK_FAILED_EXIT)
        self.assertEqual(self.asc.writes(), [CANCEL])
        self.assertIn("did not finish within 10 minutes", printed)
        self.assertIn("cannot be edited, so nothing was restored", printed)
        self.assertIn("Done: nothing. Not done: rename back to 1.35.0, re-attach build 42", printed)
        self.assertGreater(self.clock[0], asc_submit.CANCEL_WAIT_SECONDS)
        self.assertLess(self.clock[0], asc_submit.CANCEL_WAIT_SECONDS + 2 * asc_submit.CANCEL_POLL_SECONDS)
        self.assert_untouched()

    def test_review_starting_during_the_cancel_fails_loudly(self):
        self.asc.cancel_ends_in = "IN_REVIEW"
        code, printed = self.run_modes("prepare")
        self.assertEqual(code, asc_submit.ROLLBACK_FAILED_EXIT)
        self.assertEqual(self.asc.writes(), [CANCEL])
        self.assertIn("went to IN_REVIEW", printed)

    def test_rename_error_resubmits_the_old_version(self):
        for status_code in (409, 500):
            with self.subTest(code=status_code):
                self.asc = FakeAsc()
                self.patch(asc_submit.urllib.request, "urlopen", self.asc)
                self.asc.fail(*RENAME, status_code)
                code, printed = self.run_modes("prepare")
                self.assertEqual(self.asc.writes(), [CANCEL, RENAME, NEW_SUBMISSION, ITEM, sent("s2")])
                self.assertIn(str(status_code), code)
                self.assert_resubmitted_as_it_was(code)

    def test_http_error_on_the_cancel_fails_loudly_without_further_writes(self):
        self.asc.fail(*CANCEL, 500)
        code, printed = self.run_modes("prepare")
        self.assertEqual(code, asc_submit.ROLLBACK_FAILED_EXIT)
        self.assertEqual(self.asc.writes(), [CANCEL])
        self.assert_untouched()

    def test_rollback_that_fails_partway_has_its_own_exit_and_names_the_steps(self):
        self.asc.fail(*LOC2, 409)
        self.asc.fail(*BUILD, 409, skip=1)
        code, printed = self.run_modes("prepare")
        self.assertEqual(code, asc_submit.ROLLBACK_FAILED_EXIT)
        self.assertEqual(self.asc.writes(), [CANCEL, RENAME, BUILD, LOC1, LOC2, RENAME, BUILD])
        self.assertIn("App Store rollback incomplete", printed)
        self.assertIn("failed at 're-attach build 42'", printed)
        self.assertIn("Done: check 1.35.0 can be edited, rename back to 1.35.0. Not done: restore What's New, "
                      "remove any phased release, resubmit 1.35.0, read back.", printed)
        self.assertNotIn("Bearer", printed)
        self.assertEqual(self.asc.versions["v135"]["versionString"], "1.35.0")
        self.assertEqual(self.asc.versions["v135"]["build"], "b43")

    def test_status_fails_unless_waiting_for_review(self):
        self.asc.versions["v135"].update(versionString="1.35.1", build="b43",
                                         state=("PREPARE_FOR_SUBMISSION",) * 2)
        self.asc.localizations["v135"]["loc1"][1] = "Faster search."
        code, _ = self.run_modes("status")
        self.assertIn("does not match", str(code))
        self.assertEqual(self.asc.writes(), [])


if __name__ == "__main__":
    unittest.main()
