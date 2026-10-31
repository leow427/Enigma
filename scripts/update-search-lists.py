#!/usr/bin/env python3
"""Refreshes the search-quality lists bundled in Enigma/Resources/SearchData (F29, spec §3.6).

Downloads pinned copies of the public lists, converts them to the app's formats and writes
them through temporary files and renames. Nothing downloads lists at app runtime.

  python3 -I scripts/update-search-lists.py                       # download and write
  python3 -I scripts/update-search-lists.py --sources <folder>    # read saved copies instead

Output files:
  unsafe.bin, spam.bin     sorted little-endian UInt64 FNV-1a-64 hashes of lowercase domains
  reliability.tsv          domain<TAB>status (gr, nc, gu, d, b), from Wikipedia's Perennial sources
  public_suffix_list.dat   Mozilla's Public Suffix List
  enigma-blocked.txt       created with a comment header if missing; curated by hand
  manifest.json            what each list came from

authority.txt, unreadable.txt, enigma-blocked.txt and overrides.tsv are curated by hand: the script
never rewrites them (it creates enigma-blocked.txt if missing), lists them under the manifest's
"curated" key and counts them towards the budget.

If a source fails to download or parse (or shrinks to under half its last entry count), the
file it feeds keeps its previous contents, the failure is printed and the exit status is 1.
"""

import argparse
import datetime
import hashlib
import ipaddress
import json
import os
import re
import struct
import sys
import tempfile
import urllib.request
from pathlib import Path

BUDGET_BYTES = 3_145_728
# Left free when filling unsafe.bin, so hand edits to the curated files don't break the budget (D49).
HEADROOM_BYTES = 16_384
REPO = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO / "Enigma" / "Resources" / "SearchData"
USER_AGENT = "Enigma-update-search-lists/1.0 (https://github.com/leow427/Enigma)"
RAW = "https://raw.githubusercontent.com"
RSP_API = ("https://en.wikipedia.org/w/api.php?action=parse&page={page}"
           "&prop=wikitext%7Crevid&format=json&formatversion=2")
RSP_PAGE = "Wikipedia:Reliable_sources/Perennial_sources"


def github(name, repo, commit, path, fmt, target, licence):
    return {
        "name": name, "format": fmt, "target": target, "licence": licence,
        "repo": f"https://github.com/{repo}", "commit": commit, "path": path,
        "url": f"{RAW}/{repo}/{commit}/{path}", "file": f"{name}.txt",
    }


PHISHING_DATABASE = ("Phishing-Database/Phishing.Database", "12a20bf8dd2b7e78d9d38fc12b3e5c970f79d1a7")
BLOCK_LIST_PROJECT = ("blocklistproject/Lists", "ee3bdbaddf49c756cf3340bb2e6a9dee5282d1c6")
POPCAR2 = ("popcar2/BadWebsiteBlocklist", "8c1cee4370955cd8fbc8a5ce57cbafd113801ab4")
AGSIMMONS = ("agsimmons/ai-content-blocklist", "91e0b84e9e389fd73df789dbdc1d507367d7f4e0")
QUENHUS = ("quenhus/uBlock-Origin-dev-filter", "393af27d4d6daaf070035e7cd56d162dac36eef5")

# Pinned 2026-10-30. To refresh: look up each repository's latest commit, update the SHA, rerun.
SOURCES = [
    github("phishing-database-active", *PHISHING_DATABASE, "phishing-domains-ACTIVE.txt",
           "domains", "unsafe", "MIT"),
    *[github(f"blocklistproject-{kind}", *BLOCK_LIST_PROJECT, f"{kind}.txt", "hosts", "unsafe", "Unlicense")
      for kind in ("malware", "phishing", "scam", "fraud")],
    github("popcar2-badwebsiteblocklist", *POPCAR2, "uBlacklist.txt", "ublacklist", "spam", "CC0-1.0"),
    github("agsimmons-ai-content-blocklist", *AGSIMMONS, "uBlacklist.txt", "ublacklist", "spam", "CC0-1.0"),
    *[github(f"quenhus-{kind.replace('_', '-')}", *QUENHUS, f"data/{kind}.txt", "ublacklist", "spam", "Unlicense")
      for kind in ("github_copycats", "npm_copycats", "seo_spam", "stackoverflow_copycats", "wikipedia_copycats")],
    {
        "name": "wikipedia-perennial-sources", "format": "rsp", "target": "reliability",
        "licence": "CC BY-SA 4.0", "url": RSP_API.format(page=RSP_PAGE),
        "page": "https://en.wikipedia.org/wiki/Wikipedia:Reliable_sources/Perennial_sources",
        "file": "perennial-sources.json",
    },
    {
        "name": "public-suffix-list", "format": "psl", "target": "psl", "licence": "MPL-2.0",
        "url": "https://publicsuffix.org/list/public_suffix_list.dat", "file": "public_suffix_list.dat",
    },
]

# D49: unsafe.bin is filled in this order until the budget is reached, so the budget drops from
# the end: malware first, then Phishing.Database, then phishing, then fraud. Scam is never dropped.
UNSAFE_KEEP_ORDER = [
    "blocklistproject-scam", "blocklistproject-fraud", "blocklistproject-phishing",
    "phishing-database-active", "blocklistproject-malware",
]
NEVER_DROPPED = {"blocklistproject-scam"}

OUTPUT_FILES = {"unsafe": "unsafe.bin", "spam": "spam.bin", "reliability": "reliability.tsv",
                "psl": "public_suffix_list.dat"}
ENIGMA_BLOCKED_HEADER = (
    "# Sites Enigma never uses, found by the search evaluation and curated by the owner.\n"
    "# One registrable domain per line; a block covers every subdomain. Lines starting with # are comments.\n"
)
STATUSES = ("gr", "nc", "gu", "d", "b")
CURATED_FILES = ("authority.txt", "unreadable.txt", "enigma-blocked.txt", "overrides.tsv")


class SourceError(Exception):
    pass


# Hashing

FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


def fnv1a64(text):
    value = FNV_OFFSET
    for byte in text.lower().encode("utf-8"):
        value ^= byte
        value = (value * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return value


def hash_file_bytes(domains):
    return b"".join(struct.pack("<Q", value) for value in sorted({fnv1a64(d) for d in domains}))


# Domains

LABEL = re.compile(r"^[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?$")
TLD = re.compile(r"^(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})$")


def normalize_domain(text):
    """The lowercase ASCII (punycode) form of a domain, or None when it isn't one."""
    domain = text.strip().lower().rstrip(".")
    if not domain or len(domain) > 253 or "." not in domain:
        return None
    try:
        ipaddress.ip_address(domain.strip("[]"))
        return None
    except ValueError:
        pass
    if not domain.isascii():
        try:
            domain = domain.encode("idna").decode("ascii")
        except UnicodeError:
            return None
    labels = domain.split(".")
    if not all(LABEL.match(label) for label in labels) or not TLD.match(labels[-1]):
        return None
    return domain


def parse_hosts(text):
    """Hosts files (`0.0.0.0 bad.example`); a lone domain on a line is accepted too."""
    domains, skipped = set(), 0
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if parts[0] in ("0.0.0.0", "127.0.0.1", "::", "::1"):
            parts = parts[1:]
        domain = normalize_domain(parts[0]) if len(parts) == 1 else None
        if domain is None or domain in ("localhost", "localhost.localdomain"):
            skipped += 1
        else:
            domains.add(domain)
    return domains, skipped


def parse_domains(text):
    domains, skipped = set(), 0
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        domain = normalize_domain(line)
        if domain is None:
            skipped += 1
        else:
            domains.add(domain)
    return domains, skipped


UBLACKLIST_DOMAIN = re.compile(r"^\*://(\*\.)?([^/*]+)/\*$")


def parse_ublacklist(text):
    """Only domain-level match patterns (`*://*.example.com/*`, `*://example.com/*`) are kept;
    path and regex entries are skipped and counted."""
    domains, skipped = set(), 0
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":  # uBlacklist's front matter
        end = next((n for n in range(1, len(lines)) if lines[n].strip() == "---"), 0)
        lines = lines[end + 1:]
    for line in lines:
        line = line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        match = UBLACKLIST_DOMAIN.match(line)
        domain = normalize_domain(match.group(2)) if match else None
        if domain is None:
            skipped += 1
        else:
            domains.add(domain)
    return domains, skipped


# Wikipedia's Perennial sources (D50)

ROW = re.compile(r"^\|-", re.MULTILINE)
STATUS = re.compile(r"\{\{\s*WP:RSPSTATUS\s*\|([^}]*)\}\}")
USES = re.compile(r"\{\{\s*WP:RSPUSES\s*\|([^}]*)\}\}")
SUBPAGE = re.compile(r"\{\{\s*(?:WP|Wikipedia):Reliable sources/Perennial sources/(\d+)\s*\}\}")


def rsp_subpages(wikitext):
    return list(dict.fromkeys(SUBPAGE.findall(wikitext)))


def rsp_subpage_file(source, number):
    return source["file"].replace(".json", f"-{number}.json")


def merge_statuses(statuses):
    """One status per domain: rows that disagree give `nc`, unless every row deprecates or
    blacklists the domain."""
    distinct = set(statuses)
    if len(distinct) == 1:
        return statuses[0]
    if distinct <= {"d", "b"}:
        return "b"
    return "nc"


def parse_rsp(wikitexts):
    found, skipped = {}, 0
    for wikitext in wikitexts:
        for row in ROW.split(wikitext)[1:]:
            status_match = STATUS.search(row)
            if not status_match:
                continue
            args = [arg.strip() for arg in status_match.group(1).split("|")]
            status = "b" if "b=y" in args[1:] else args[0]
            uses = [arg.strip() for match in USES.findall(row) for arg in match.split("|")]
            uses = [use for use in uses if use and "=" not in use]
            if status not in STATUSES:
                skipped += len(uses) or 1
                continue
            for use in uses:
                domain = normalize_domain(use.removeprefix("www.")) if "/" not in use else None
                if domain is None:
                    skipped += 1
                else:
                    found.setdefault(domain, []).append(status)
    if not found:
        raise SourceError("no rows with a status and a domain")
    return {domain: merge_statuses(statuses) for domain, statuses in found.items()}, skipped


# The Public Suffix List, for removing subdomains of listed domains

class PublicSuffixList:
    def __init__(self, text):
        self.rules, self.wildcards, self.exceptions = set(), set(), set()
        for line in text.splitlines():
            rule = line.strip().split()[0] if line.strip() else ""
            if not rule or rule.startswith("//"):
                continue
            rule = ".".join(normalize_label(label) for label in rule.split("."))
            if rule.startswith("!"):
                self.exceptions.add(rule[1:])
            elif rule.startswith("*."):
                self.wildcards.add(rule[2:])
            else:
                self.rules.add(rule)

    def registrable(self, domain):
        labels = domain.split(".")
        for n in range(len(labels)):
            candidate = ".".join(labels[n:])
            if candidate in self.exceptions:
                return candidate
            parent = ".".join(labels[n + 1:])
            if candidate in self.rules or (n + 1 < len(labels) and parent in self.wildcards):
                return ".".join(labels[n - 1:]) if n > 0 else None
        return ".".join(labels[-2:]) if len(labels) >= 2 else None


def normalize_label(label):
    if label.isascii() or label in ("*", "!"):
        return label.lower()
    prefix = "!" if label.startswith("!") else ""
    try:
        return prefix + label.removeprefix("!").encode("idna").decode("ascii")
    except UnicodeError:
        return label.lower()


def parse_psl(text):
    if "===BEGIN ICANN DOMAINS===" not in text:
        raise SourceError("no ICANN section")
    return PublicSuffixList(text)


def ancestors(domain, psl):
    """The parents the app checks: down to the registrable domain."""
    floor = psl.registrable(domain) if psl else None
    if floor is None or floor == domain:
        return []
    labels = domain.split(".")
    stop = len(floor.split("."))
    return [".".join(labels[n:]) for n in range(1, len(labels) - stop + 1)]


def collapse(domains, psl):
    return {domain for domain in domains if not any(parent in domains for parent in ancestors(domain, psl))}


# Fetching

def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200:
            raise SourceError(f"HTTP {response.status}")
        return response.read()


def read_source(source, sources_dir):
    """The raw bytes of one file, from the saved copies or the network."""
    if sources_dir is not None:
        path = Path(sources_dir) / source["file"]
        if not path.exists():
            raise SourceError(f"no saved copy {source['file']}")
        return path.read_bytes()
    return fetch(source["url"])


def load_source(source, sources_dir):
    """Returns (parsed, entries, skipped, version, sha256)."""
    raw = read_source(source, sources_dir)
    digest = hashlib.sha256(raw)
    text = raw.decode("utf-8", errors="replace")
    fmt = source["format"]
    if fmt == "psl":
        psl = parse_psl(text)
        version = re.search(r"^// VERSION: (\S+)", text, re.MULTILINE)
        return (psl, text), len(psl.rules) + len(psl.wildcards) + len(psl.exceptions), 0, \
            (version.group(1) if version else "unversioned"), digest.hexdigest()
    if fmt == "rsp":
        main = parse_rsp_page(raw)
        wikitexts, versions = [main["wikitext"]], [f"rev {main['revid']}"]
        for number in rsp_subpages(main["wikitext"]):
            if sources_dir is not None:
                path = Path(sources_dir) / rsp_subpage_file(source, number)
                if not path.exists():
                    raise SourceError(f"no saved copy {path.name}")
                page_raw = path.read_bytes()
            else:
                page_raw = fetch(RSP_API.format(page=f"{RSP_PAGE}/{number}"))
            digest.update(page_raw)
            page = parse_rsp_page(page_raw)
            wikitexts.append(page["wikitext"])
            versions.append(f"/{number} rev {page['revid']}")
        statuses, skipped = parse_rsp(wikitexts)
        return statuses, len(statuses), skipped, "; ".join(versions), digest.hexdigest()
    parser = {"hosts": parse_hosts, "domains": parse_domains, "ublacklist": parse_ublacklist}[fmt]
    domains, skipped = parser(text)
    if not domains:
        raise SourceError("no entries")
    return domains, len(domains), skipped, source["commit"], digest.hexdigest()


def parse_rsp_page(raw):
    try:
        page = json.loads(raw)["parse"]
        return {"wikitext": page["wikitext"], "revid": int(page["revid"])}
    except (ValueError, KeyError, TypeError) as error:
        raise SourceError(f"unexpected API response ({type(error).__name__})") from None


# Writing

def write_atomically(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(handle, "wb") as file:
            file.write(data)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def curated_entries(output, files):
    """The hand-curated files, with their entry counts and hashes."""
    entries = []
    for name in CURATED_FILES:
        data = files.get(name)
        if data is None and (output / name).exists():
            data = (output / name).read_bytes()
        if data is None:
            continue
        lines = data.decode("utf-8", errors="replace").splitlines()
        count = sum(1 for line in lines if line.strip() and not line.lstrip().startswith("#"))
        entries.append({"name": name, "entries": count, "sha256": hashlib.sha256(data).hexdigest()})
    return entries


def manifest_bytes(generated, entries, total, curated=()):
    manifest = {"generated": generated, "budgetBytes": BUDGET_BYTES, "totalBytes": total, "sources": entries,
                "curated": list(curated)}
    return (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def allowed_domains(output):
    """The `allow` domains of the curated overrides.tsv (D56): the app lifts spam and Perennial
    blocks for them, so their own unsafe-list entries must never be trimmed (D60)."""
    try:
        text = (Path(output) / "overrides.tsv").read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return set()
    allowed = set()
    for line in text.splitlines():
        fields = line.strip().split("\t")
        if len(fields) == 2 and not fields[0].startswith("#") and fields[1] == "allow":
            domain = normalize_domain(fields[0])
            if domain:
                allowed.add(domain)
    return allowed


def fit_unsafe(by_source, psl, available_bytes, protected_under=()):
    """Fills unsafe.bin in `UNSAFE_KEEP_ORDER` until it fits (D49). Entries equal to or under a
    `protected_under` domain are always kept (D60). Returns the domains kept and how many of each
    source's domains are no longer blocked."""
    def protected(domain):
        return any(domain == p or domain.endswith("." + p) for p in protected_under)

    kept = set()
    for name in UNSAFE_KEEP_ORDER:
        kept |= by_source.get(name, set())
    kept = collapse(kept, psl)
    capacity = available_bytes // 8
    if len(kept) > capacity:
        kept = collapse({d for domains in by_source.values() for d in domains if protected(d)}, psl)
        if len(kept) > capacity:
            return None, {}
        for name in UNSAFE_KEEP_ORDER:
            candidates = collapse(kept | by_source.get(name, set()), psl)
            if len(candidates) <= capacity:
                kept = candidates
                continue
            if name in NEVER_DROPPED:
                return None, {}
            new = sorted(candidates - kept, key=lambda d: (d.count("."), len(d), d))
            kept = kept | set(new[:max(0, capacity - len(kept))])
            kept = collapse(kept, psl)
    dropped = {}
    for name, domains in by_source.items():
        dropped[name] = sum(1 for d in domains if d not in kept and not any(p in kept for p in ancestors(d, psl)))
    return kept, dropped


def run(output=DEFAULT_OUTPUT, sources=None, budget=BUDGET_BYTES, today=None, headroom=None):
    output = Path(output)
    today = today or datetime.date.today().isoformat()
    headroom = HEADROOM_BYTES if headroom is None else headroom
    previous = {}
    manifest_path = output / "manifest.json"
    if manifest_path.exists():
        try:
            previous = {s["name"]: s for s in json.loads(manifest_path.read_text(encoding="utf-8"))["sources"]}
        except (ValueError, KeyError, TypeError):
            previous = {}

    loaded, failures = {}, {}
    for source in SOURCES:
        name = source["name"]
        try:
            parsed, entries, skipped, version, sha256 = load_source(source, sources)
            last = previous.get(name, {}).get("entries")
            if isinstance(last, int) and entries * 2 < last:  # D51
                raise SourceError(f"{entries} entries, under half of the last {last}")
            loaded[name] = {"parsed": parsed, "entry": {
                "name": name, "format": source["format"],
                "url": source["url"],
                "version": version, "fetched": today, "entries": entries, "skipped": skipped,
                "dropped": 0, "licence": source["licence"], "sha256": sha256,
            }}
        except (SourceError, OSError, ValueError) as error:
            failures[name] = str(error) or type(error).__name__

    failed_targets = {source["target"] for source in SOURCES if source["name"] in failures}
    files = {}

    psl = None
    if "psl" not in failed_targets:
        psl, psl_text = loaded["public-suffix-list"]["parsed"]
        files["public_suffix_list.dat"] = psl_text.encode("utf-8")
    elif (output / "public_suffix_list.dat").exists():
        psl = PublicSuffixList((output / "public_suffix_list.dat").read_text(encoding="utf-8"))

    if "spam" not in failed_targets:
        spam = set()
        for source in SOURCES:
            if source["target"] == "spam":
                spam |= loaded[source["name"]]["parsed"]
        files["spam.bin"] = hash_file_bytes(collapse(spam, psl))

    if "reliability" not in failed_targets:
        statuses = loaded["wikipedia-perennial-sources"]["parsed"]
        files["reliability.tsv"] = "".join(f"{d}\t{statuses[d]}\n" for d in sorted(statuses)).encode("utf-8")

    if not (output / "enigma-blocked.txt").exists():
        files["enigma-blocked.txt"] = ENIGMA_BLOCKED_HEADER.encode("utf-8")

    entries = []
    for source in SOURCES:
        name = source["name"]
        if name in loaded and source["target"] not in failed_targets:
            entries.append(loaded[name]["entry"])
        elif name in previous:
            entries.append(previous[name])
        else:
            entries.append({"name": name, "format": source["format"], "url": source["url"], "version": "missing",
                            "fetched": None, "entries": 0, "skipped": 0, "dropped": 0,
                            "licence": source["licence"], "sha256": "0" * 64})

    def size_of(name):
        if name in files:
            return len(files[name])
        path = output / name
        return path.stat().st_size if path.exists() else 0

    existing = {path.name for path in output.iterdir() if path.is_file() and not path.name.startswith(".")} \
        if output.exists() else set()
    others = (existing | set(files)) - {"unsafe.bin", "manifest.json"}
    fixed = sum(size_of(name) for name in others)
    # The manifest's own size, with room for the totals' digits.
    curated = curated_entries(output, files)
    manifest_estimate = len(manifest_bytes(today, entries, budget, curated)) + 64

    if "unsafe" not in failed_targets:
        by_source = {s["name"]: loaded[s["name"]]["parsed"] for s in SOURCES if s["target"] == "unsafe"}
        unsafe, dropped = fit_unsafe(by_source, psl, budget - headroom - fixed - manifest_estimate,
                                     allowed_domains(output))
        if unsafe is None:
            print(f"error: the lists don't fit the {budget}-byte budget even after dropping every "
                  "droppable entry", file=sys.stdout)
            return 1
        files["unsafe.bin"] = hash_file_bytes(unsafe)
        for entry in entries:
            if entry["name"] in dropped:
                entry["dropped"] = dropped[entry["name"]]

    total_without_manifest = fixed + size_of("unsafe.bin")
    manifest = manifest_bytes(today, entries, 0, curated)
    for _ in range(3):
        manifest = manifest_bytes(today, entries, total_without_manifest + len(manifest), curated)
    total = total_without_manifest + len(manifest)
    if total > budget:
        print(f"error: the folder would be {total} bytes, over the {budget}-byte budget", file=sys.stdout)
        return 1

    for name, data in files.items():
        write_atomically(output / name, data)
    write_atomically(manifest_path, manifest)

    for entry in entries:
        note = f", {entry['dropped']} dropped for the budget" if entry.get("dropped") else ""
        print(f"{entry['name']}: {entry['entries']} entries, {entry['skipped']} skipped{note}")
    print(f"total {total} bytes of {budget}")
    for name, reason in failures.items():
        print(f"error: {name} failed ({reason}); its list keeps its previous file")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="the SearchData folder to write")
    parser.add_argument("--sources", help="read saved copies from this folder instead of downloading")
    args = parser.parse_args(argv)
    return run(output=args.output, sources=args.sources)


if __name__ == "__main__":
    sys.exit(main())
