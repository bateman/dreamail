#!/usr/bin/env python3
"""Tell CI whether a change needs the macOS build and unit tests.

Usage: needs-build.py BASE    (run from the repository root)

Prints `build=true` or `build=false`, a line for $GITHUB_OUTPUT. It prints
`false` only when every file that differs between BASE and HEAD is one
that neither the build nor any unit test reads: SKIP_DIRS and SKIP_FILES.
An empty or all-zero BASE, a BASE git cannot resolve and an empty diff all
print `true`, so a doubt runs the tests.

The list is not "every Markdown file": the unit tests read README.md,
CONTRIBUTING.md and SECURITY.md, and walk Sources, Tests, scripts, .github,
Config and Design. test_ci_checks.py fails if a test that reads repository
files names one of the paths below.

Standard library only.
"""

from __future__ import annotations

import subprocess
import sys

SKIP_DIRS = ("docs/", "reviews/", ".claude/")
SKIP_FILES = ("CHANGELOG.md", "CLAUDE.md")


def skippable(path: str) -> bool:
    return path.startswith(SKIP_DIRS) or path in SKIP_FILES


def needs_build(paths: list[str]) -> bool:
    return not paths or not all(skippable(path) for path in paths)


def changed_paths(base: str) -> list[str] | None:
    """Paths that differ between BASE and HEAD; None when BASE is unusable."""
    if not base.strip("0"):
        return None
    # --no-renames: a file moved from Sources/ to docs/ must list Sources/.
    result = subprocess.run(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"],
        capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return None
    return [path for path in result.stdout.split("\0") if path]


def main(argv: list[str]) -> int:
    paths = changed_paths(argv[0] if argv else "")
    if paths is None:
        print("No usable base commit: build and test", file=sys.stderr)
        build = True
    else:
        build = needs_build(paths)
        print(f"{len(paths)} changed file(s); build and test: {build}", file=sys.stderr)
    print(f"build={'true' if build else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
