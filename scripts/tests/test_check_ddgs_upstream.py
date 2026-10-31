"""Offline tests for scripts/check-ddgs-upstream.py.

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ddgs-upstream"
UPSTREAM = {
    "project": "ddgs",
    "repository": "https://github.com/deedy5/ddgs",
    "license": "MIT",
    "tag": "v9.16.1",
    "commit": "8e74959141106702645020dcb853c6453b5e5195",
    "files": {
        "ddgs/engines/duckduckgo.py": {
            "blob": "6396dbab0f0751c572176a8a2d93a3b226ad03b0",
            "port": "Enigma/Search/Engines/DuckDuckGoEngine.swift",
        },
        "ddgs/engines/wikipedia.py": {
            "blob": "51df186fc9564ce1a1a6b8327e4597110e1a5f34",
            "port": "Enigma/Search/Engines/WikipediaSearch.swift",
        },
    },
}


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


watch = load("check_ddgs_upstream", "check-ddgs-upstream.py")


class CheckDdgsUpstreamTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.upstream = self.folder / "UPSTREAM.json"
        self.upstream.write_text(json.dumps(UPSTREAM))

    def run_script(self, fixtures):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            status = watch.main(["--api-fixtures", str(fixtures), "--upstream", str(self.upstream)])
        return status, (json.loads(out.getvalue()) if out.getvalue() else None)

    def test_detects_changed_files(self):
        status, report = self.run_script(FIXTURES / "changed")
        self.assertEqual(status, 0)
        self.assertEqual(report["tag"], "v9.17.0")
        self.assertEqual(report["changed"], ["ddgs/engines/duckduckgo.py"])

    def test_no_change_reports_empty(self):
        status, report = self.run_script(FIXTURES / "unchanged")
        self.assertEqual(status, 0)
        self.assertEqual(report["tag"], "v9.16.1")
        self.assertEqual(report["changed"], [])

    def test_compare_url(self):
        _, report = self.run_script(FIXTURES / "changed")
        self.assertEqual(report["compare"], "https://github.com/deedy5/ddgs/compare/v9.16.1...v9.17.0")

    def test_removed_file_counts_as_changed(self):
        fixtures = self.folder / "removed"
        shutil.copytree(FIXTURES / "unchanged", fixtures)
        (fixtures / "contents" / "ddgs" / "engines" / "wikipedia.py.json").unlink()
        status, report = self.run_script(fixtures)
        self.assertEqual(status, 0)
        self.assertEqual(report["changed"], ["ddgs/engines/wikipedia.py"])

    def test_errors_exit_one(self):
        fixtures = self.folder / "broken"
        shutil.copytree(FIXTURES / "unchanged", fixtures)
        (fixtures / "release.json").write_text("not json")
        status, report = self.run_script(fixtures)
        self.assertEqual(status, 1)
        self.assertIsNone(report)

    def test_unreadable_upstream_exits_one(self):
        self.upstream.write_text(json.dumps({"tag": "v1"}))
        status, report = self.run_script(FIXTURES / "unchanged")
        self.assertEqual(status, 1)
        self.assertIsNone(report)

    def test_empty_files_rejected(self):
        self.upstream.write_text(json.dumps(dict(UPSTREAM, files={})))
        status, report = self.run_script(FIXTURES / "unchanged")
        self.assertEqual(status, 1)
        self.assertIsNone(report)

    def test_repository_must_be_github(self):
        for repository in ["https://example.com/deedy5/ddgs", "http://github.com/deedy5/ddgs",
                           "https://github.com/deedy5"]:
            self.upstream.write_text(json.dumps(dict(UPSTREAM, repository=repository)))
            status, report = self.run_script(FIXTURES / "unchanged")
            self.assertEqual(status, 1, repository)
            self.assertIsNone(report)

    def test_only_github_api_urls(self):
        self.assertEqual(watch.api_url("deedy5/ddgs", "releases/latest"),
                         "https://api.github.com/repos/deedy5/ddgs/releases/latest")
        self.assertEqual(watch.api_url("deedy5/ddgs", "contents/ddgs/engines/duckduckgo.py", ref="v9.17.0"),
                         "https://api.github.com/repos/deedy5/ddgs/contents/ddgs/engines/duckduckgo.py?ref=v9.17.0")


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()


class LiveAPITests(unittest.TestCase):
    """The live client with `urlopen` replaced: nothing reaches the network."""

    def get(self, environment, respond):
        requests = []

        def urlopen(request, timeout):
            requests.append(request)
            return respond(request)

        with mock.patch.dict(watch.os.environ, environment, clear=True), \
                mock.patch.object(watch.urllib.request, "urlopen", urlopen):
            result = watch.LiveAPI("deedy5/ddgs").get("contents/ddgs/engines/duckduckgo.py", ref="v9.16.1")
        return result, requests

    def test_404_is_none(self):
        def missing(request):
            raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)
        result, _ = self.get({}, missing)
        self.assertIsNone(result)

    def test_other_errors_raise(self):
        def forbidden(request):
            raise urllib.error.HTTPError(request.full_url, 403, "Forbidden", {}, None)
        with self.assertRaises(watch.WatchError):
            self.get({}, forbidden)

    def test_no_token_header_without_token(self):
        result, requests = self.get({}, lambda request: FakeResponse(b'{"sha": "abc"}'))
        self.assertEqual(result, {"sha": "abc"})
        self.assertIsNone(requests[0].get_header("Authorization"))
        self.assertEqual(requests[0].full_url,
                         "https://api.github.com/repos/deedy5/ddgs/contents/ddgs/engines/duckduckgo.py?ref=v9.16.1")

    def test_token_header_with_token(self):
        _, requests = self.get({"GITHUB_TOKEN": "test-token"}, lambda request: FakeResponse(b"{}"))
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer test-token")


if __name__ == "__main__":
    unittest.main()
