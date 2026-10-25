#!/usr/bin/env python3
"""Pick the driver version for a local build so every build is newer than the last.

Versions are YYYYMMDDNN integers: the date plus a two-digit build number for that
day (00, 01, ...), which the GitHub updater compares against release tags
(vYYYYMMDDNN). A build gets today's date with 00, or one more than the last
version built from this checkout when that is already today or later, so builds
on the same day never share a version and Composer always sees an update.
Older 8-digit versions (YYYYMMDD) are always lower, so they update cleanly.

Usage:
  driver_version.py next <state-file>            # print the version to use
  driver_version.py record <state-file> <ver>    # remember a version as built
"""

import datetime
import sys
from pathlib import Path


def last_built(state: Path) -> int:
    try:
        return int(state.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return 0


def next_version(state: Path) -> int:
    today = int(datetime.date.today().strftime("%Y%m%d")) * 100
    return max(today, last_built(state) + 1)


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "next":
        print(next_version(Path(argv[2])))
        return 0
    if len(argv) == 4 and argv[1] == "record":
        version = int(argv[3])
        state = Path(argv[2])
        if version > last_built(state):
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(f"{version}\n", encoding="utf-8")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
