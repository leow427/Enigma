#!/usr/bin/env python3
"""Warns when the bundled search lists are more than 60 days old.

Usage: python3 -I scripts/check-search-lists-age.py [--manifest <path>] [--today YYYY-MM-DD]

Reads `generated` from Enigma/Resources/SearchData/manifest.json. It only
warns, and always exits 0, so `scripts/release.sh` never stops on it.
Standard library only.
"""

import argparse
import datetime
import json
import sys
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = REPOSITORY_ROOT / "Enigma" / "Resources" / "SearchData" / "manifest.json"
MAXIMUM_AGE_DAYS = 60


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", default=str(MANIFEST))
    parser.add_argument("--today", help="the date to compare with (default: today)")
    arguments = parser.parse_args(argv)
    try:
        generated = json.loads(Path(arguments.manifest).read_text())["generated"]
        age = (datetime.date.fromisoformat(arguments.today) if arguments.today else datetime.date.today()) \
            - datetime.date.fromisoformat(generated)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"warning: can't tell how old the search lists are ({error}). "
              "Run scripts/update-search-lists.py before releasing.")
        return 0
    if age.days > MAXIMUM_AGE_DAYS:
        print(f"warning: search lists are {age.days} days old. "
              "Run scripts/update-search-lists.py before releasing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
