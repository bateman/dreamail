#!/usr/bin/env python3
"""Fail a CI test job whose xcodebuild log shows a test skipped unexpectedly.

A skipped XCTest counts as a pass, so a test that cannot find what it needs
(for example the built app the signature and updater tests inspect) would
turn green without checking anything. This reads the log of a test run and
fails when:

  * the log has no "Executed N tests" summary with N > 0, or
  * any test was skipped that is not listed in the allowlist file.

The allowlist (.github/test-skip-allowlist.txt) names tests whose skip
depends on the runner, one `Class.testMethod` per line, `#` for comments.
An allowlisted test that did not skip is reported, so stale entries show.

Usage: check-test-skips.py LOG [ALLOWLIST]
"""

import re
import sys
from pathlib import Path

SKIPPED = re.compile(r"Test Case '-\[(?:[\w.]+\.)?(?P<cls>\w+) (?P<test>\w+)\]' skipped")
EXECUTED = re.compile(r"Executed (?P<count>\d+) tests?, with")
DEFAULT_ALLOWLIST = Path(__file__).resolve().parent.parent / "test-skip-allowlist.txt"


def read_allowlist(path: Path) -> set[str]:
    entries = set()
    for line in path.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            entries.add(entry)
    return entries


def main(argv: list[str]) -> int:
    if not 1 <= len(argv) <= 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    log = Path(argv[0]).read_text(errors="replace")
    allowed = read_allowlist(Path(argv[1]) if len(argv) == 2 else DEFAULT_ALLOWLIST)

    counts = [int(m["count"]) for m in EXECUTED.finditer(log)]
    if not counts or max(counts) == 0:
        print("::error::No 'Executed N tests' summary with N > 0 in the test log")
        return 1

    skipped = sorted({f"{m['cls']}.{m['test']}" for m in SKIPPED.finditer(log)})
    unexpected = [name for name in skipped if name not in allowed]

    print(f"Executed {max(counts)} tests; {len(skipped)} skipped")
    for name in skipped:
        print(f"  skipped: {name}{'' if name in allowed else '  <- NOT ALLOWED'}")
    for name in sorted(allowed - set(skipped)):
        print(f"  note: allowlisted {name} ran this time")

    if unexpected:
        for name in unexpected:
            print(f"::error::{name} was skipped; a skipped test proves nothing. "
                  "Fix what it needs, or allowlist it with a reason in "
                  ".github/test-skip-allowlist.txt")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
