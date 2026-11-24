#!/usr/bin/env python3
"""Tripwire: fail if project.yml stops pinning its Swift packages by commit.

What enforces what (see docs/DEPENDENCIES.md):
  * the `revision:` pin fixes the package's Package.swift, and with it the
    binary target's checksum;
  * SwiftPM refuses a downloaded binary whose SHA-256 differs from that
    checksum;
  * CI and `make release` delete SourcePackages before building, so every
    such build downloads, and SwiftPM verifies, the binary again.

This script guards only the first link. Like check-workflows.py it catches
regressions in review and is not a security boundary: a pull request can
edit it too. It is line-based and fails closed: it accepts only the plain
form below, and anything else in the areas it covers is a violation.

  * Top level: every line is a plain `key:` (letters only, unquoted, no
    tags, anchors or merge keys), each key at most once, and none of
    `include`, `localPackages` or `projectReferences`, which can bring in
    packages or dependencies from elsewhere.
  * `packages:` holds `  Name:` entries, each with exactly one
    `    url: https://...` and one `    revision: <40-hex SHA>` and nothing
    else, so `exactVersion`, `from`, `branch`, `path` and similar are out.
    A package name appears at most once.
  * No `framework:` or `carthage:` dependency anywhere: a prebuilt binary
    must come through a pinned package.

Standard library only. Exit status 1 lists every violation.
"""

import re
import sys
from pathlib import Path

PROJECT = Path("project.yml")
TOP_KEY = re.compile(r"^([A-Za-z]+):(?: .*)?$")
FORBIDDEN_TOP = {"include", "localPackages", "projectReferences"}
PACKAGE_NAME = re.compile(r"^  ([A-Za-z0-9_-]+):$")
PACKAGE_FIELD = re.compile(r"^    (url|revision): (\S+)$")
URL = re.compile(r"^https://[A-Za-z0-9.-]+/[A-Za-z0-9_./-]+$")
SHA = re.compile(r"^[0-9a-f]{40}$")
BINARY_DEPENDENCY = re.compile(r"""(?:^|[\s{,\-"'])(?:framework|carthage)["']?\s*:""")


def code_part(line: str) -> str:
    """The line without a trailing ` # comment`; '' for comment-only lines."""
    if line.lstrip().startswith("#"):
        return ""
    return line.split(" #", 1)[0].rstrip()


def check(path: Path = PROJECT) -> list[str]:
    errors = []
    top_keys: set[str] = set()
    packages: dict[str, dict[str, str]] = {}
    current = None
    in_packages = False

    for number, line in enumerate(path.read_text().splitlines(), start=1):
        where = f"{path}:{number}"
        code = code_part(line)
        if not code.strip():
            continue

        if BINARY_DEPENDENCY.search(code):
            errors.append(f"{where}: `framework:` and `carthage:` dependencies are not "
                          "allowed; add a binary through a package pinned by `revision:`")

        if not code.startswith((" ", "\t")):
            in_packages = False
            match = TOP_KEY.match(code)
            if not match:
                errors.append(f"{where}: unsupported top-level form; use a plain `key:` "
                              "(no quotes, tags, anchors or merge keys)")
                continue
            key = match[1]
            if key in top_keys:
                errors.append(f"{where}: top-level `{key}` appears twice")
            top_keys.add(key)
            if key in FORBIDDEN_TOP:
                errors.append(f"{where}: `{key}` is not allowed; it can bring in packages "
                              "or dependencies this check does not see")
            if key == "packages":
                if code != "packages:":
                    errors.append(f"{where}: use a block `packages:` mapping")
                in_packages = True
            continue

        if not in_packages:
            continue
        if match := PACKAGE_NAME.match(code):
            current = match[1]
            if current in packages:
                errors.append(f"{where}: package `{current}` is declared twice")
            packages[current] = {}
        elif (match := PACKAGE_FIELD.match(code)) and current is not None:
            field, value = match[1], match[2]
            if field in packages[current]:
                errors.append(f"{where}: `{field}` appears twice in package `{current}`")
            packages[current][field] = value
            if field == "url" and not URL.match(value):
                errors.append(f"{where}: `url` must be a plain https:// URL")
            if field == "revision" and not SHA.match(value):
                errors.append(f"{where}: `revision` must be a full 40-hex commit SHA")
        else:
            errors.append(f"{where}: unsupported form in `packages:`; each package takes "
                          "only `url:` and `revision:` (a full commit SHA), since tags "
                          "and branches can move")

    for name, fields in packages.items():
        for field in ("url", "revision"):
            if field not in fields:
                errors.append(f"{path}: package `{name}` has no `{field}:`")
    return errors


def main(argv: list[str]) -> int:
    path = Path(argv[0]) if argv else PROJECT
    errors = check(path)
    for error in errors:
        print(error)
    if errors:
        print(f"{len(errors)} package pin violation(s)")
        return 1
    print(f"Package pins OK: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
