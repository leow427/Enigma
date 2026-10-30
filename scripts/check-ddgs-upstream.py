#!/usr/bin/env python3
"""Reports which ddgs files Enigma ports changed in ddgs's latest release.

Usage: python3 -I scripts/check-ddgs-upstream.py [--api-fixtures <folder>] [--upstream <path>]

Reads Enigma/Search/Engines/UPSTREAM.json (the tag and blob SHA of each ported
file), asks GitHub's API for ddgs's latest release, then for each recorded
file's blob SHA at that tag, and prints JSON:

    {"tag": "<latest tag>", "changed": [paths], "compare": "<compare URL>"}

A path is listed when its blob differs or it no longer exists. Only
api.github.com is contacted; never a search site. GITHUB_TOKEN, when set, is
sent as a bearer token for the higher rate limit. With --api-fixtures, saved
responses are read instead: <folder>/release.json and
<folder>/contents/<path>.json (a missing file is a 404).

Exits 0 whether or not anything changed, and 1 on any error.
Standard library only.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = REPOSITORY_ROOT / "Enigma" / "Search" / "Engines" / "UPSTREAM.json"
API = "https://api.github.com/repos/"
TIMEOUT = 30


class WatchError(Exception):
    pass


def api_url(repository, path, ref=None):
    url = API + repository + "/" + urllib.parse.quote(path)
    if ref is not None:
        url += "?" + urllib.parse.urlencode({"ref": ref})
    return url


def load_upstream(path):
    try:
        data = json.loads(Path(path).read_text())
        repository = urllib.parse.urlsplit(data["repository"])
        if repository.scheme != "https" or repository.netloc != "github.com":
            raise WatchError(f"{path}: repository must be a https://github.com/ URL")
        name = repository.path.strip("/")
        if name.count("/") != 1:
            raise WatchError(f"{path}: repository must name owner/name")
        files = {file: entry["blob"] for file, entry in data["files"].items()}
        if not files:
            raise WatchError(f"{path}: no files recorded")
        return name, data["tag"], files
    except WatchError:
        raise
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise WatchError(f"can't read {path}: {error}") from error


class LiveAPI:
    def __init__(self, repository):
        self.repository = repository
        self.headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "Enigma-ddgs-watch",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            self.headers["Authorization"] = "Bearer " + token

    def get(self, path, ref=None):
        """The parsed JSON at path, or None for a 404."""
        request = urllib.request.Request(api_url(self.repository, path, ref), headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise WatchError(f"GitHub API {path}: HTTP {error.code}") from error
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise WatchError(f"GitHub API {path}: {error}") from error


class FixtureAPI:
    def __init__(self, folder):
        self.folder = Path(folder)

    def get(self, path, ref=None):
        if path == "releases/latest":
            file = self.folder / "release.json"
        elif path.startswith("contents/"):
            # The saved contents are the latest release's, so any other ref is a bug.
            release = self.get("releases/latest")
            tag = release.get("tag_name") if isinstance(release, dict) else None
            if ref is None or ref != tag:
                raise WatchError(f"fixture {path} asked at ref {ref!r}, not the latest tag {tag!r}")
            file = self.folder / (path + ".json")
        else:
            raise WatchError(f"no fixture for {path}")
        if not file.is_file():
            return None
        try:
            return json.loads(file.read_text())
        except ValueError as error:
            raise WatchError(f"fixture {file}: {error}") from error


def check(api, repository, recorded_tag, files):
    release = api.get("releases/latest")
    if not isinstance(release, dict) or not isinstance(release.get("tag_name"), str):
        raise WatchError("the latest release has no tag")
    tag = release["tag_name"]
    changed = []
    for path, blob in files.items():
        entry = api.get("contents/" + path, ref=tag)
        if entry is None:
            changed.append(path)
            continue
        if not isinstance(entry, dict) or not isinstance(entry.get("sha"), str):
            raise WatchError(f"{path} at {tag}: no sha in the response")
        if entry["sha"] != blob:
            changed.append(path)
    compare = f"https://github.com/{repository}/compare/{recorded_tag}...{tag}"
    return {"tag": tag, "changed": sorted(changed), "compare": compare}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--api-fixtures", help="read saved API responses from this folder")
    parser.add_argument("--upstream", default=str(UPSTREAM), help="the UPSTREAM.json to compare")
    arguments = parser.parse_args(argv)
    try:
        repository, recorded_tag, files = load_upstream(arguments.upstream)
        api = FixtureAPI(arguments.api_fixtures) if arguments.api_fixtures else LiveAPI(repository)
        report = check(api, repository, recorded_tag, files)
    except WatchError as error:
        print(f"check-ddgs-upstream: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
