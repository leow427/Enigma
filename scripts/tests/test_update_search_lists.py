"""Offline tests for scripts/update-search-lists.py.

Run with: python3 -I -B -m unittest discover -s scripts/tests
"""

import importlib.util
import io
import json
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "search-lists"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lists = load("update_search_lists", "update-search-lists.py")


def fixture(name):
    return (FIXTURES / name).read_text(encoding="utf-8")


def rsp_page(wikitext, revid):
    return json.dumps({"parse": {"title": "x", "revid": revid, "wikitext": wikitext}})


def write_sources(folder, overrides=None):
    """Writes a saved copy of every source into `folder`, as `--sources` reads them."""
    overrides = overrides or {}
    folder.mkdir(parents=True, exist_ok=True)
    for source in lists.SOURCES:
        name = source["name"]
        if source["format"] == "rsp":
            main = "Intro text.\n{{WP:Reliable sources/Perennial sources/1}}\n"
            (folder / source["file"]).write_text(overrides.get(name, rsp_page(main, 100)), encoding="utf-8")
            (folder / lists.rsp_subpage_file(source, "1")).write_text(
                rsp_page(fixture("rsp-excerpt.wikitext"), 101), encoding="utf-8")
            continue
        default = {
            "hosts": fixture("hosts.txt"),
            "domains": fixture("domains.txt"),
            "ublacklist": fixture("ublacklist.txt"),
            "psl": fixture("public_suffix_list.dat"),
        }[source["format"]]
        (folder / source["file"]).write_text(overrides.get(name, default), encoding="utf-8")


def run_quietly(**kwargs):
    kwargs.setdefault("headroom", 0)
    out = io.StringIO()
    with redirect_stdout(out):
        status = lists.run(**kwargs)
    return status, out.getvalue()


def read_hashes(path):
    data = path.read_bytes()
    return [struct.unpack_from("<Q", data, offset)[0] for offset in range(0, len(data), 8)]


class UpdateSearchListsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sources = self.root / "sources"
        self.output = self.root / "SearchData"

    def tearDown(self):
        self.tmp.cleanup()

    def test_fnv1a64_vectors(self):
        self.assertEqual(lists.fnv1a64("example.com"), 0x576846634E2714C6)
        self.assertEqual(lists.fnv1a64("bbc.co.uk"), 0x37560E87B6FC872C)
        self.assertEqual(lists.fnv1a64(""), 0xCBF29CE484222325)
        self.assertEqual(lists.fnv1a64("Example.COM"), lists.fnv1a64("example.com"))

    def test_hosts_format(self):
        domains, skipped = lists.parse_hosts(fixture("hosts.txt"))
        self.assertEqual(domains, {"bad.example", "worse.example", "tracker.example", "plain-line.example"})
        # "0.0.0.0 0.0.0.0", "localhost", "not a domain" and the IP address.
        self.assertEqual(skipped, 4)

    def test_domains_format(self):
        domains, skipped = lists.parse_domains(fixture("domains.txt"))
        self.assertEqual(domains, {"phish.example", "login-verify.example", "sub.phish.example"})
        self.assertEqual(skipped, 1)

    def test_ublacklist_domain_entries(self):
        domains, skipped = lists.parse_ublacklist(fixture("ublacklist.txt"))
        self.assertEqual(domains, {"example.com", "example.org"})
        self.assertEqual(skipped, 2)

    def test_hash_file_is_sorted_little_endian(self):
        data = lists.hash_file_bytes({"example.com", "bbc.co.uk", "a.example"})
        self.assertEqual(len(data), 24)
        values = [struct.unpack_from("<Q", data, offset)[0] for offset in (0, 8, 16)]
        self.assertEqual(values, sorted(values))
        self.assertIn(0x576846634E2714C6, values)
        self.assertEqual(data[data.index(struct.pack("<Q", 0x576846634E2714C6)):][:8],
                         bytes([0xC6, 0x14, 0x27, 0x4E, 0x63, 0x46, 0x68, 0x57]))

    def test_rsp_statuses(self):
        statuses, skipped = lists.parse_rsp([fixture("rsp-excerpt.wikitext")])
        self.assertEqual(statuses, {
            "reliable.example": "gr",
            "reliable-paper.example": "gr",
            "mixed.example": "nc",
            "tabloid.example": "gu",
            "fabricator.example": "d",
            "spamfarm.example": "b",
        })
        # The path entry and the row without a single status.
        self.assertEqual(skipped, 2)

    def test_rsp_conflicting_rows(self):
        rows = (
            '|- class="s-gr" id="A"\n| {{WP:RSPSTATUS|gr}}\n| {{WP:RSPUSES|shared.example|both-bad.example}}\n'
            '|- class="s-gu" id="B"\n| {{WP:RSPSTATUS|gu}}\n| {{WP:RSPUSES|shared.example}}\n'
            '|- class="s-d" id="C"\n| {{WP:RSPSTATUS|d}}\n| {{WP:RSPUSES|bad.example}}\n'
            '|- class="s-b" id="D"\n| {{WP:RSPSTATUS|d|b=y}}\n| {{WP:RSPUSES|bad.example}}\n'
        )
        statuses, _ = lists.parse_rsp([rows])
        self.assertEqual(statuses["shared.example"], "nc")
        self.assertEqual(statuses["bad.example"], "b")

    def test_rsp_reliable_and_deprecated_rows_give_no_consensus(self):
        rows = (
            '|- class="s-gr" id="A"\n| {{WP:RSPSTATUS|gr}}\n| {{WP:RSPUSES|split.example}}\n'
            '|- class="s-d" id="B"\n| {{WP:RSPSTATUS|d}}\n| {{WP:RSPUSES|split.example}}\n'
        )
        statuses, _ = lists.parse_rsp([rows])
        self.assertEqual(statuses["split.example"], "nc")

    def test_collapse_stops_at_the_registrable_domain(self):
        psl = lists.PublicSuffixList(fixture("public_suffix_list.dat"))
        self.assertIsNone(psl.registrable("000webhostapp.com"))
        self.assertEqual(psl.registrable("evil.000webhostapp.com"), "evil.000webhostapp.com")
        kept = lists.collapse({"000webhostapp.com", "evil.000webhostapp.com", "bad.example", "a.bad.example"}, psl)
        self.assertEqual(kept, {"000webhostapp.com", "evil.000webhostapp.com", "bad.example"})

    def test_failed_write_leaves_the_old_file(self):
        target = self.root / "out" / "unsafe.bin"
        target.parent.mkdir()
        target.write_bytes(b"old")
        original = lists.os.replace

        def failing_replace(*args):
            raise OSError("disk full")
        lists.os.replace = failing_replace
        try:
            with self.assertRaises(OSError):
                lists.write_atomically(target, b"new contents")
        finally:
            lists.os.replace = original
        self.assertEqual(target.read_bytes(), b"old")
        self.assertEqual([path.name for path in target.parent.iterdir()], ["unsafe.bin"])

    def test_rsp_subpages(self):
        main = "x {{WP:Reliable sources/Perennial sources/1}} {{WP:Reliable sources/Perennial sources/12}} y"
        self.assertEqual(lists.rsp_subpages(main), ["1", "12"])

    def test_full_run_writes_every_file(self):
        write_sources(self.sources)
        status, _ = run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        self.assertEqual(status, 0)
        for name in ("unsafe.bin", "spam.bin", "reliability.tsv", "public_suffix_list.dat", "manifest.json",
                     "enigma-blocked.txt"):
            self.assertTrue((self.output / name).exists(), name)
        unsafe = set(read_hashes(self.output / "unsafe.bin"))
        self.assertIn(lists.fnv1a64("bad.example"), unsafe)
        self.assertIn(lists.fnv1a64("phish.example"), unsafe)
        # A subdomain of a listed domain adds nothing: the lookup checks parents.
        self.assertNotIn(lists.fnv1a64("sub.phish.example"), unsafe)
        spam = set(read_hashes(self.output / "spam.bin"))
        self.assertEqual(spam, {lists.fnv1a64("example.com"), lists.fnv1a64("example.org")})
        tsv = (self.output / "reliability.tsv").read_text(encoding="utf-8")
        self.assertIn("fabricator.example\td\n", tsv)
        self.assertNotIn(".tmp", "".join(path.name for path in self.output.iterdir()))

    def test_budget_drops_phishing_first(self):
        phishing = "\n".join(f"phish{n}.example" for n in range(200)) + "\n"
        write_sources(self.sources, {"phishing-database-active": phishing})
        status, _ = run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        self.assertEqual(status, 0)
        full = (self.output / "unsafe.bin").stat().st_size
        total = json.loads((self.output / "manifest.json").read_text())["totalBytes"]

        # 50 hashes fewer than the full folder needs: Phishing.Database gives them up.
        output = self.root / "Tight"
        status, _ = run_quietly(output=output, sources=self.sources, today="2026-10-30", budget=total - 400)
        self.assertEqual(status, 0)
        manifest = json.loads((output / "manifest.json").read_text())
        dropped = {source["name"]: source["dropped"] for source in manifest["sources"]}
        self.assertGreaterEqual(dropped["phishing-database-active"], 50)
        self.assertEqual(dropped["blocklistproject-phishing"], 0)
        self.assertEqual(dropped["blocklistproject-scam"], 0)
        self.assertLessEqual(manifest["totalBytes"], total - 400)
        self.assertLess((output / "unsafe.bin").stat().st_size, full)
        kept = set(read_hashes(output / "unsafe.bin"))
        self.assertIn(lists.fnv1a64("bad.example"), kept)  # the scam list's entries stay

    def test_budget_drops_malware_before_phishing(self):
        malware = "\n".join(f"0.0.0.0 malware{n}.example" for n in range(100)) + "\n"
        write_sources(self.sources, {"blocklistproject-malware": malware})
        status, _ = run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        total = json.loads((self.output / "manifest.json").read_text())["totalBytes"]
        output = self.root / "Tight"
        status, _ = run_quietly(output=output, sources=self.sources, today="2026-10-30", budget=total - 400)
        self.assertEqual(status, 0)
        dropped = {s["name"]: s["dropped"] for s in json.loads((output / "manifest.json").read_text())["sources"]}
        self.assertGreaterEqual(dropped["blocklistproject-malware"], 50)
        self.assertEqual(dropped["phishing-database-active"], 0)

    def test_budget_keeps_security_entries_under_allowed_domains(self):
        # D59/D60: an `allow` override must never leave a malware-listed subdomain unblocked.
        malware = "\n".join(f"0.0.0.0 malware{n}.example" for n in range(100)) + "\n0.0.0.0 zone.msn.example\n"
        write_sources(self.sources, {"blocklistproject-malware": malware})
        overrides = "msn.example\tallow\nwiki.example\tneutral\n"
        for folder in (self.output, self.root / "Tight"):
            folder.mkdir(parents=True)
            (folder / "overrides.tsv").write_text(overrides, encoding="utf-8")
        run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        total = json.loads((self.output / "manifest.json").read_text())["totalBytes"]
        status, _ = run_quietly(output=self.root / "Tight", sources=self.sources, today="2026-10-30",
                                budget=total - 400)
        self.assertEqual(status, 0)
        manifest = json.loads((self.root / "Tight" / "manifest.json").read_text())
        dropped = {s["name"]: s["dropped"] for s in manifest["sources"]}
        self.assertGreaterEqual(dropped["blocklistproject-malware"], 50)
        kept = set(read_hashes(self.root / "Tight" / "unsafe.bin"))
        self.assertIn(lists.fnv1a64("zone.msn.example"), kept)

    def test_budget_fails_when_nothing_left_to_drop(self):
        write_sources(self.sources)
        status, out = run_quietly(output=self.output, sources=self.sources, today="2026-10-30", budget=1000)
        self.assertEqual(status, 1)
        self.assertIn("budget", out.lower())
        self.assertFalse((self.output / "unsafe.bin").exists())

    def test_failure_keeps_last_good(self):
        write_sources(self.sources)
        self.assertEqual(run_quietly(output=self.output, sources=self.sources, today="2026-10-30")[0], 0)
        before_tsv = (self.output / "reliability.tsv").read_bytes()
        before_spam = (self.output / "spam.bin").read_bytes()
        before_manifest = json.loads((self.output / "manifest.json").read_text())

        # Wikipedia's page is broken; a uBlacklist list gains an entry.
        broken = self.root / "broken"
        write_sources(broken, {
            "wikipedia-perennial-sources": "{not json",
            "popcar2-badwebsiteblocklist": fixture("ublacklist.txt") + "*://*.new-spam.example/*\n",
        })
        status, out = run_quietly(output=self.output, sources=broken, today="2026-10-31")
        self.assertEqual(status, 1)
        self.assertIn("wikipedia-perennial-sources", out)
        self.assertEqual((self.output / "reliability.tsv").read_bytes(), before_tsv)
        self.assertNotEqual((self.output / "spam.bin").read_bytes(), before_spam)
        manifest = json.loads((self.output / "manifest.json").read_text())
        old = next(s for s in before_manifest["sources"] if s["name"] == "wikipedia-perennial-sources")
        new = next(s for s in manifest["sources"] if s["name"] == "wikipedia-perennial-sources")
        self.assertEqual(new, old)
        self.assertNotIn(".tmp", "".join(path.name for path in self.output.iterdir()))

    def test_list_shrinking_by_half_is_a_failure(self):
        write_sources(self.sources)
        self.assertEqual(run_quietly(output=self.output, sources=self.sources, today="2026-10-30")[0], 0)
        before = (self.output / "unsafe.bin").read_bytes()
        shrunk = self.root / "shrunk"
        write_sources(shrunk, {"blocklistproject-scam": "0.0.0.0 bad.example\n"})
        status, out = run_quietly(output=self.output, sources=shrunk, today="2026-10-31")
        self.assertEqual(status, 1)
        self.assertIn("blocklistproject-scam", out)
        self.assertEqual((self.output / "unsafe.bin").read_bytes(), before)

    def test_headroom_is_left_free(self):
        write_sources(self.sources, {"phishing-database-active": "\n".join(f"p{n}.example" for n in range(200))})
        run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        total = json.loads((self.output / "manifest.json").read_text())["totalBytes"]
        output = self.root / "Headroom"
        status, _ = run_quietly(output=output, sources=self.sources, today="2026-10-30", budget=total, headroom=800)
        self.assertEqual(status, 0)
        self.assertLessEqual(json.loads((output / "manifest.json").read_text())["totalBytes"], total - 800)

    def test_files_are_world_readable(self):
        write_sources(self.sources)
        run_quietly(output=self.output, sources=self.sources, today="2026-10-30")
        for path in self.output.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o644, path.name)

    def test_curated_files_are_kept_and_listed(self):
        write_sources(self.sources)
        self.output.mkdir(parents=True)
        overrides = "# reviewed\nwikipedia.org\tneutral\nmsn.com\tallow\n"
        (self.output / "overrides.tsv").write_text(overrides, encoding="utf-8")
        (self.output / "authority.txt").write_text("# x\n.gov\nnhs.uk\n", encoding="utf-8")
        self.assertEqual(run_quietly(output=self.output, sources=self.sources, today="2026-10-30")[0], 0)
        self.assertEqual((self.output / "overrides.tsv").read_text(encoding="utf-8"), overrides)
        manifest = json.loads((self.output / "manifest.json").read_text())
        curated = {entry["name"]: entry for entry in manifest["curated"]}
        self.assertEqual(curated["overrides.tsv"]["entries"], 2)
        self.assertEqual(curated["authority.txt"]["entries"], 2)
        self.assertEqual(curated["enigma-blocked.txt"]["entries"], 0)
        self.assertEqual(len(curated["overrides.tsv"]["sha256"]), 64)
        on_disk = sum(path.stat().st_size for path in self.output.iterdir() if path.is_file())
        self.assertEqual(manifest["totalBytes"], on_disk)

    def test_manifest_fields(self):
        write_sources(self.sources)
        self.assertEqual(run_quietly(output=self.output, sources=self.sources, today="2026-10-30")[0], 0)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["generated"], "2026-10-30")
        self.assertEqual(manifest["budgetBytes"], 3145728)
        on_disk = sum(path.stat().st_size for path in self.output.iterdir() if path.is_file())
        self.assertEqual(manifest["totalBytes"], on_disk)
        self.assertEqual({s["name"] for s in manifest["sources"]}, {s["name"] for s in lists.SOURCES})
        for source in manifest["sources"]:
            for key in ("name", "url", "version", "fetched", "entries", "skipped", "licence", "sha256"):
                self.assertIn(key, source, f"{source['name']} lacks {key}")
            self.assertEqual(len(source["sha256"]), 64)
            self.assertTrue(source["url"].startswith("https://"))
        rsp = next(s for s in manifest["sources"] if s["name"] == "wikipedia-perennial-sources")
        self.assertIn("100", rsp["version"])
        self.assertIn("101", rsp["version"])
        self.assertEqual(rsp["licence"], "CC BY-SA 4.0")
        psl = next(s for s in manifest["sources"] if s["format"] == "psl")
        self.assertEqual(psl["licence"], "MPL-2.0")
        for source in lists.SOURCES:
            if source["format"] not in ("rsp", "psl"):
                self.assertRegex(source.get("commit") or "", r"^[0-9a-f]{40}$", source["name"])
                self.assertIn(source["commit"], source["url"])

    def test_sources_are_pinned_and_licensed(self):
        targets = {}
        for source in lists.SOURCES:
            targets.setdefault(source["target"], []).append(source["name"])
            self.assertTrue(source["licence"])
        self.assertEqual(len(targets["spam"]), 7)  # popcar2, agsimmons, and quenhus's five files
        self.assertEqual(len(targets["unsafe"]), 5)
        self.assertEqual(targets["reliability"], ["wikipedia-perennial-sources"])


if __name__ == "__main__":
    unittest.main()
