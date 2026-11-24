#!/usr/bin/env python3
"""Tripwire: fail if a GitHub Actions workflow loses its hardening.

This catches regressions in review; it is not a security boundary, since a
pull request can edit this checker too. Server-side enforcement is the
repository setting "Require actions to be pinned to a full-length commit
SHA" plus the default read-only GITHUB_TOKEN.

It fails closed: it accepts only the plain block forms below, and any other
line that mentions `uses` or `permissions` is a violation, so flow mappings,
quoted keys, refs on the next line and similar variants are rejected by
construction rather than chased one by one.

  * A top-level `permissions:` block must exist, and each entry under it
    must be `read` or `none`. A job that needs more opens its own indented
    `permissions:` block. Inline forms (`write-all`, `{ ... }`) are rejected.
  * Every step `uses:` must be `owner/repo[/path]@<40-hex SHA> # vX.Y.Z`.
    Local `./` actions and `docker://` images are rejected; none are used.
    The version comment is not checked against the SHA (that needs the
    network); Dependabot (.github/dependabot.yml) keeps the two in step.
  * No `brew install|reinstall|upgrade|bundle`, which take the newest
    formula and cannot pin a version (see install-xcodegen.sh).
  * No `pull_request_target` or `workflow_run` triggers, which run with
    the base repository's secrets and write token on untrusted input.

Standard library only, line-based. Exit status 1 lists every violation.
"""

import re
import sys
from pathlib import Path

USES = re.compile(
    r"^\s*(?:- )?uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?"
    r"@[0-9a-f]{40} # v\d+(?:\.\d+)*$"
)
PERMISSIONS_BLOCK = re.compile(r"^(?P<indent> *)permissions:$")
READ_ENTRY = re.compile(r"^ +[a-z-]+: (?:read|none)$")
BREW = re.compile(r"\bbrew\b.*\b(?:install|reinstall|upgrade|bundle)\b")
TRIGGERS = re.compile(r"\b(?:pull_request_target|workflow_run)\b")


def code_part(line: str) -> str:
    """The line without a trailing ` # comment`; '' for comment-only lines."""
    if line.lstrip().startswith("#"):
        return ""
    return line.split(" #", 1)[0].rstrip()


def check(path: Path) -> list[str]:
    errors = []
    lines = path.read_text().splitlines()
    top_level = False
    in_top_block = False

    for number, line in enumerate(lines, start=1):
        where = f"{path}:{number}"
        code = code_part(line)
        if not code.strip():
            continue

        if in_top_block:
            if code.startswith(" "):
                if not READ_ENTRY.match(code):
                    errors.append(f"{where}: top-level permissions may only be `read` or "
                                  "`none`; raise a scope in the job that needs it")
                continue
            in_top_block = False

        if re.search(r"\bpermissions\b", code):
            match = PERMISSIONS_BLOCK.match(code)
            if not match:
                errors.append(f"{where}: unsupported permissions form; use a block "
                              "`permissions:` with one `scope: level` per line")
            elif match["indent"] == "":
                top_level = in_top_block = True

        if re.search(r"\buses\b", code) and not USES.match(line):
            errors.append(f"{where}: `uses:` must be `owner/repo@<full commit SHA> # vX.Y.Z` "
                          "on one line, as a plain block key")

        # Join shell continuations so `brew \` + newline + `install` is seen.
        logical, follow = code, number
        while logical.endswith("\\") and follow < len(lines):
            logical = logical[:-1] + " " + code_part(lines[follow])
            follow += 1
        if BREW.search(logical):
            errors.append(f"{where}: Homebrew cannot pin a version; install a "
                          "checksummed release instead (see install-xcodegen.sh)")

        if TRIGGERS.search(code):
            errors.append(f"{where}: `pull_request_target` and `workflow_run` are not allowed")

    if not top_level:
        errors.insert(0, f"{path}: no top-level `permissions:` block (use `contents: read`)")
    return errors


def main(argv: list[str]) -> int:
    if argv:
        paths = [Path(arg) for arg in argv]
    else:
        root = Path(".github/workflows")
        paths = sorted([*root.glob("*.yml"), *root.glob("*.yaml")])
        if not paths:
            print(f"No workflow files found under {root}", file=sys.stderr)
            return 1

    errors = [error for path in paths for error in check(path)]
    for error in errors:
        print(error)
    if errors:
        print(f"{len(errors)} workflow hardening violation(s)")
        return 1
    print(f"Workflow hardening OK: {len(paths)} file(s) checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
