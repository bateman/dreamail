#!/usr/bin/env python3
"""Fail if a GitHub Actions workflow loses its supply-chain hardening.

Checks every workflow file given (default: .github/workflows/*.yml|yaml):

  * a top-level `permissions:` block exists and grants nothing beyond read
    (a job that needs more raises it in its own `permissions:`);
  * no `permissions: write-all` anywhere;
  * every `uses:` of a remote action or reusable workflow names a full
    40-character commit SHA, followed by a `# <version>` comment so the
    pin can be reviewed and updated (local `./` actions and `docker://`
    images pinned by `@sha256:` digest are accepted);
  * no `brew install`, which always takes the newest formula and so cannot
    pin a tool's version (see .github/scripts/install-xcodegen.sh).

Standard library only, line-based: the runners have no YAML module and these
rules need no full parse. Exit status 1 lists every violation found.
"""

import re
import sys
from pathlib import Path

SHA_REF = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@\s]+)?@[0-9a-f]{40}$")
DOCKER_DIGEST = re.compile(r"^docker://[^@\s]+@sha256:[0-9a-f]{64}$")
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(?P<ref>[^\s#]+)\s*(?P<comment>#.*)?$")
VERSION_COMMENT = re.compile(r"^#\s*v?\d+(\.\d+)*\S*")
PERMISSIONS = re.compile(r"^(?P<indent>\s*)permissions:\s*(?P<value>[^#]*?)\s*(#.*)?$")
BREW_INSTALL = re.compile(r"\bbrew\s+install\b")


def check(path: Path) -> list[str]:
    errors = []
    lines = path.read_text().splitlines()
    top_level_permissions = None

    for number, line in enumerate(lines, start=1):
        where = f"{path}:{number}"
        if line.lstrip().startswith("#"):
            continue

        match = PERMISSIONS.match(line)
        if match:
            value = match["value"].strip("'\"")
            if value == "write-all":
                errors.append(f"{where}: `permissions: write-all` is not allowed")
            if match["indent"] == "":
                top_level_permissions = number
                if value in ("", "{}"):
                    # Block form: every entry below must be read or none.
                    for offset, entry in enumerate(lines[number:], start=number + 1):
                        if entry.strip() == "" or entry.lstrip().startswith("#"):
                            continue
                        if not entry.startswith((" ", "\t")):
                            break
                        scope, _, level = entry.split("#")[0].partition(":")
                        if level.strip() not in ("read", "none"):
                            errors.append(
                                f"{path}:{offset}: top-level `{scope.strip()}: {level.strip()}` "
                                "grants more than read; raise it in the job that needs it"
                            )
                elif value != "read-all":
                    errors.append(
                        f"{where}: top-level `permissions: {value}` grants more than read"
                    )

        match = USES.match(line)
        if match:
            ref = match["ref"].strip("'\"")
            if ref.startswith("./"):
                pass
            elif ref.startswith("docker://"):
                if not DOCKER_DIGEST.match(ref):
                    errors.append(f"{where}: `{ref}` is not pinned to an @sha256: digest")
            elif not SHA_REF.match(ref):
                errors.append(f"{where}: `{ref}` is not pinned to a full commit SHA")
            elif not (match["comment"] and VERSION_COMMENT.match(match["comment"])):
                errors.append(f"{where}: `{ref}` needs a trailing `# vX.Y.Z` version comment")

        if BREW_INSTALL.search(line):
            errors.append(
                f"{where}: `brew install` cannot pin a version; install a checksummed "
                "release instead (see .github/scripts/install-xcodegen.sh)"
            )

    if top_level_permissions is None:
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
