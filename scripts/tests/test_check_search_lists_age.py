"""Offline tests for scripts/check-search-lists-age.py.

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


age = load("check_search_lists_age", "check-search-lists-age.py")


class CheckSearchListsAgeTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)
        self.manifest = self.folder / "manifest.json"
        self.manifest.write_text(json.dumps({"generated": "2026-01-01", "sources": []}))

    def run_script(self, today):
        out = io.StringIO()
        with redirect_stdout(out):
            status = age.main(["--manifest", str(self.manifest), "--today", today])
        return status, out.getvalue()

    def test_warns_after_sixty_days(self):
        status, output = self.run_script("2026-03-03")  # 61 days
        self.assertEqual(status, 0)
        self.assertEqual(output.strip(), "warning: search lists are 61 days old. "
                         "Run scripts/update-search-lists.py before releasing.")

    def test_quiet_within_sixty_days(self):
        status, output = self.run_script("2026-03-02")  # 60 days
        self.assertEqual(status, 0)
        self.assertEqual(output, "")

    def test_unreadable_manifest_warns_and_exits_zero(self):
        self.manifest.write_text("{")
        status, output = self.run_script("2026-03-02")
        self.assertEqual(status, 0)
        self.assertTrue(output.startswith("warning: "))

    def test_missing_manifest_warns_and_exits_zero(self):
        self.manifest.unlink()
        status, output = self.run_script("2026-03-02")
        self.assertEqual(status, 0)
        self.assertTrue(output.startswith("warning: "))


if __name__ == "__main__":
    unittest.main()
