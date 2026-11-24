#!/usr/bin/env python3
"""Check that Swift packages are pinned by commit and resolve to that commit.

The pins live in .github/package-pins.txt (url, revision and binary-target
checksum per package). Two modes:

  check-package-pins.py
      Static, before any build (the "Workflow hardening" job). Every package
      in project.yml must be a plain `url:` + `revision: <40-hex SHA>` block
      that matches the pins; `exactVersion`, `from`, `branch` and other
      version rules are rejected, as is a package with no pin or a pin with
      no package. Like check-workflows.py this is a tripwire, not a boundary.

  check-package-pins.py --resolved <derived data dir>
      After xcodebuild has resolved packages (the unit job). For each pin,
      the SwiftPM checkout under <dir>/SourcePackages/checkouts must be at
      the pinned commit and its Package.swift must declare exactly the
      pinned binary checksum, and the generated project's Package.resolved
      must record the pinned revision. SwiftPM itself refuses a downloaded
      binary whose SHA-256 differs from the manifest's checksum, so a match
      here ties the built binary to the recorded value.

Standard library only. Exit status 1 lists every violation.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

PINS = Path(".github/package-pins.txt")
PROJECT = Path("project.yml")
RESOLVED = Path("MishMail.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
FIELDS = ("url", "revision", "checksum")
SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CHECKSUM = re.compile(r'checksum:\s*"([0-9a-fA-F]+)"')
HOW_TO_UPGRADE = ("If this is a deliberate upgrade, update the revision in project.yml and "
                  f"the revision and checksum in {PINS} together; see docs/DEPENDENCIES.md.")


def read_pins(path: Path = PINS) -> tuple[dict[str, dict[str, str]], list[str]]:
    pins: dict[str, dict[str, str]] = {}
    errors = []
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 3 or parts[1] not in FIELDS:
            errors.append(f"{path}:{number}: expected `<package> <{'|'.join(FIELDS)}> <value>`")
            continue
        name, field, value = parts
        if field in pins.setdefault(name, {}):
            errors.append(f"{path}:{number}: {name} {field} is pinned twice")
        pins[name][field] = value
    for name, fields in pins.items():
        for field in FIELDS:
            if field not in fields:
                errors.append(f"{path}: {name} has no {field} pin")
        if "revision" in fields and not SHA.match(fields["revision"]):
            errors.append(f"{path}: {name} revision must be a full 40-hex commit SHA")
        if "checksum" in fields and not SHA256.match(fields["checksum"]):
            errors.append(f"{path}: {name} checksum must be a 64-hex SHA-256")
    if not pins:
        errors.append(f"{path}: no pins")
    return pins, errors


def read_project_packages(path: Path = PROJECT) -> tuple[dict[str, dict[str, str]], list[str]]:
    """The `packages:` block of project.yml, accepting only plain block form."""
    packages: dict[str, dict[str, str]] = {}
    errors = []
    current = None
    in_block = False
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        code = "" if line.lstrip().startswith("#") else line.split(" #", 1)[0].rstrip()
        if not code.strip():
            continue
        if not code.startswith(" "):
            in_block = code == "packages:"
            if not in_block and code.startswith("packages"):
                errors.append(f"{path}:{number}: use a block `packages:` mapping")
            continue
        if not in_block:
            continue
        if match := re.match(r"^  ([A-Za-z0-9_.-]+):$", code):
            current = match[1]
            packages[current] = {}
        elif (match := re.match(r"^    ([A-Za-z]+): (\S+)$", code)) and current:
            packages[current][match[1]] = match[2]
        else:
            errors.append(f"{path}:{number}: unsupported form in `packages:`; "
                          "use `Name:` then `url:` and `revision:` lines")
    return packages, errors


def check_static(pins_path: Path = PINS, project_path: Path = PROJECT) -> list[str]:
    pins, errors = read_pins(pins_path)
    packages, project_errors = read_project_packages(project_path)
    errors += project_errors
    for name, keys in packages.items():
        where = f"{project_path}: package {name}"
        extra = sorted(set(keys) - {"url", "revision"})
        if extra:
            errors.append(f"{where} uses {', '.join(extra)}; pin it with `revision:` "
                          "(a full commit SHA) and nothing else, since tags and branches can move")
        if "revision" not in keys:
            errors.append(f"{where} has no `revision:`")
        if name not in pins:
            errors.append(f"{where} has no entry in {pins_path}")
            continue
        for field in ("url", "revision"):
            if field in keys and keys[field] != pins[name].get(field):
                errors.append(f"{where} {field} is {keys[field]}, {pins_path} records "
                              f"{pins[name].get(field)}. {HOW_TO_UPGRADE}")
    for name in pins:
        if name not in packages:
            errors.append(f"{pins_path}: {name} is pinned but project.yml has no such package")
    return errors


def repo_name(url: str) -> str:
    name = url.rstrip("/").rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".git") else name


def check_resolved(derived: Path, pins_path: Path = PINS,
                   resolved_path: Path = RESOLVED) -> list[str]:
    pins, errors = read_pins(pins_path)
    if errors:
        return errors

    resolved_pins = {}
    if resolved_path.is_file():
        for pin in json.loads(resolved_path.read_text()).get("pins", []):
            location = pin.get("location") or pin.get("repositoryURL") or ""
            resolved_pins[repo_name(location).lower()] = pin.get("state", {}).get("revision")
    else:
        errors.append(f"{resolved_path}: not found; was the project generated and built?")

    for name, pin in pins.items():
        repo = repo_name(pin["url"])
        if resolved_path.is_file():
            got = resolved_pins.get(repo.lower())
            if got != pin["revision"]:
                errors.append(f"{name}: Package.resolved records revision {got}, expected "
                              f"{pin['revision']}. {HOW_TO_UPGRADE}")

        checkout = derived / "SourcePackages" / "checkouts" / repo
        if not checkout.is_dir():
            errors.append(f"{name}: no SwiftPM checkout at {checkout}")
            continue
        head = subprocess.run(["git", "-C", str(checkout), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if head != pin["revision"]:
            errors.append(f"{name}: checkout {checkout} is at {head or 'an unknown commit'}, "
                          f"expected {pin['revision']}. {HOW_TO_UPGRADE}")
        manifest = checkout / "Package.swift"
        sums = CHECKSUM.findall(manifest.read_text()) if manifest.is_file() else []
        if sums != [pin["checksum"]]:
            errors.append(f"{name}: {manifest} declares binary checksum(s) "
                          f"{', '.join(sums) or 'none'}, expected exactly {pin['checksum']}. "
                          f"{HOW_TO_UPGRADE}")
    return errors


def main(argv: list[str]) -> int:
    if argv[:1] == ["--resolved"] and len(argv) == 2:
        errors, mode = check_resolved(Path(argv[1])), "resolved packages"
    elif not argv:
        errors, mode = check_static(), "project.yml package pins"
    else:
        print("usage: check-package-pins.py [--resolved <derived data dir>]", file=sys.stderr)
        return 2
    for error in errors:
        print(f"::error::{error}" if "GITHUB_ACTIONS" in os.environ else error)
    if errors:
        print(f"{len(errors)} package pin violation(s)")
        return 1
    pins, _ = read_pins()
    for name, pin in pins.items():
        print(f"{name}: {pin['url']} @ {pin['revision']} (binary sha256 {pin['checksum']})")
    print(f"Package pins OK: {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
