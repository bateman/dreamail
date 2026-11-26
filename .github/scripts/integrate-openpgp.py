#!/usr/bin/env python3
"""Prepares the integration of a dreamail-openpgp release: the edits the
Integrate dreamail-openpgp workflow commits on its branch, after checking the
release (docs/DEPENDENCIES.md, "OpenPGP library").

  1. Picks the release: the version given, or the newest vX.Y.Z tag of
     dreamail-openpgp. A downgrade is refused.
  2. Finds the commit on its main whose Package.swift points at that
     release (the commit DreaMail pins), and reads from it the checksum, the
     rPGP version and licence, the crate count and the accepted advisories.
  3. Checks that the checksum in Package.swift, the release's .sha256 asset
     and the SHA-256 of the downloaded zip agree.
  4. Edits project.yml (revision and its version comment),
     docs/DEPENDENCIES.md (table and a "Recorded for" note) and CHANGELOG.md.
  5. Writes the pull request body to build/openpgp-integration.md and, under
     GitHub Actions, the outputs (changed, version, commit, review).

`review=true` means a change needs a person: the accepted advisories
(DEC-051) differ from the table's. The workflow then does not merge.

Usage: .github/scripts/integrate-openpgp.py [VERSION]
Exit status: 0 done or already integrated, 1 a check failed, 2 bad input.
Standard library and git only.
"""

import datetime
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
UPSTREAM = "https://github.com/bateman/dreamail-openpgp"
ASSET = "DreaMailRPGP.xcframework.zip"
PROJECT = REPO / "project.yml"
DEPENDENCIES = REPO / "docs" / "DEPENDENCIES.md"
CHANGELOG = REPO / "CHANGELOG.md"
BODY = REPO / "build" / "openpgp-integration.md"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
SHA = re.compile(r"^[0-9a-f]{40}$")


class Failure(Exception):
    """A check failed: nothing is edited."""


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def git(*args: str, cwd: Path | None = None) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise Failure(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


# Reading the release -------------------------------------------------------

def release_tags() -> list[str]:
    tags = []
    for line in git("ls-remote", "--tags", UPSTREAM).splitlines():
        ref = line.split("\t")[1]
        match = re.fullmatch(r"refs/tags/v(\d+\.\d+\.\d+)", ref)
        if match:
            tags.append(match.group(1))
    return sorted(tags, key=version_key)


def package_fields(manifest: str) -> tuple[str, str]:
    version = re.search(r'^let version = "([^"]+)"$', manifest, re.M)
    checksum = re.search(r'^let checksum = "([0-9a-f]{64})"$', manifest, re.M)
    if not version or not checksum:
        raise Failure("Package.swift has no plain `let version` and `let checksum`")
    return version.group(1), checksum.group(1)


def pinning_commit(clone: Path, version: str) -> str:
    """The newest commit on main whose Package.swift declares `version`."""
    for commit in git("log", "--format=%H", "origin/main", "--", "Package.swift", cwd=clone).split():
        if package_fields(git("show", f"{commit}:Package.swift", cwd=clone))[0] == version:
            return commit
    raise Failure(f"no commit on dreamail-openpgp main points Package.swift at v{version} "
                  "(is its Package.swift pull request merged?)")


def library_facts(clone: Path, commit: str) -> dict:
    show = lambda path: git("show", f"{commit}:{path}", cwd=clone)  # noqa: E731
    pgp = re.search(r'^pgp = \{ version = "=([^"]+)"', show("rust/Cargo.toml"), re.M)
    crates = re.search(r"^(\d+) crates\.$", show("THIRD_PARTY_LICENSES.md"), re.M)
    licence = re.search(r"^\| rPGP \| crate `pgp` `=[^`]+` \([^)]*\), (.+) \|$", show("README.md"), re.M)
    if not (pgp and crates and licence):
        raise Failure("cannot read the rPGP version, crate count or licence at that commit")
    return {
        "pgp": pgp.group(1),
        "crates": int(crates.group(1)),
        "licence": licence.group(1),
        "advisories": sorted(set(re.findall(r'id = "(RUSTSEC-\d{4}-\d{4})"', show("rust/deny.toml")))),
    }


# Editing DreaMail -----------------------------------------------------------

def sub_once(pattern: str, replacement: str, text: str, what: str) -> str:
    new, count = re.subn(pattern, replacement, text, count=0, flags=re.M)
    if count != 1:
        raise Failure(f"expected one {what}, found {count}")
    return new


def current_pin(project: str) -> str:
    match = re.search(r"^  DreaMailRPGP:\n    url: \S+\n    revision: ([0-9a-f]{40})$", project, re.M)
    if not match:
        raise Failure("project.yml: no DreaMailRPGP package with a revision")
    return match.group(1)


def edit_project(project: str, version: str, commit: str) -> str:
    project = sub_once(r"(^  DreaMailRPGP:\n    url: \S+\n    revision: )[0-9a-f]{40}$",
                       rf"\g<1>{commit}", project, "DreaMailRPGP revision")
    return sub_once(r"(checksummed static xcframework\. Release )v\d+\.\d+\.\d+(, pinned)",
                    rf"\g<1>v{version}\g<2>", project, "release comment in project.yml")


def openpgp_section(dependencies: str) -> tuple[int, int]:
    """Start and end of the "## OpenPGP library" section: the edits stay in it."""
    start = dependencies.find("\n## OpenPGP library\n")
    if start < 0:
        raise Failure("docs/DEPENDENCIES.md: no `## OpenPGP library` section")
    end = dependencies.find("\n## ", start + 1)
    return start, len(dependencies) if end < 0 else end


def section(dependencies: str) -> str:
    start, end = openpgp_section(dependencies)
    return dependencies[start:end]


def current_release(dependencies: str) -> str:
    match = re.search(r"^\| Release \| `v(\d+\.\d+\.\d+)` \|$", section(dependencies), re.M)
    if not match:
        raise Failure("docs/DEPENDENCIES.md: no OpenPGP Release row")
    return match.group(1)


def table_advisories(dependencies: str) -> list[str]:
    match = re.search(r"^\| Accepted advisories \(DEC-051\) \| (.+) \|$", section(dependencies), re.M)
    if not match:
        raise Failure("docs/DEPENDENCIES.md: no accepted advisories row")
    return sorted(set(re.findall(r"RUSTSEC-\d{4}-\d{4}", match.group(1))))


def edit_dependencies(dependencies: str, old: dict, new: dict) -> str:
    start, end = openpgp_section(dependencies)
    text = dependencies[start:end]
    v = new["version"]
    text = sub_once(r"^(\| Release \| )`v[^`]+`( \|)$", rf"\g<1>`v{v}`\g<2>", text, "Release row")
    text = sub_once(r"^(\| Commit \(`revision:` in `project.yml`\) \| )`[0-9a-f]{40}`( \|)$",
                    rf"\g<1>`{new['commit']}`\g<2>", text, "Commit row")
    text = sub_once(r"^(\| Binary \| `DreaMailRPGP\.xcframework\.zip` from the )`v[^`]+`( GitHub release)",
                    rf"\g<1>`v{v}`\g<2>", text, "Binary row")
    text = sub_once(r"^(\| Binary SHA-256 \(declared in `Package.swift` at that commit\) \| )`[0-9a-f]{64}`( \|)$",
                    rf"\g<1>`{new['checksum']}`\g<2>", text, "Binary SHA-256 row")
    text = sub_once(r"^(\| Recorded \| ).+( \|)$", rf"\g<1>{new['date']}\g<2>", text, "Recorded row")
    text = sub_once(r"^(\| Contents \| rPGP \(`pgp` =)[^,]+, [^)]+(\) and )\d+( crates in all)",
                    rf"\g<1>{new['pgp']}, {new['licence']}\g<2>{new['crates']}\g<3>", text, "Contents row")
    note = (f"Recorded for `v{v}`: the checksum in `Package.swift` at the commit, the release's "
            f"`.sha256` asset and the SHA-256 of the downloaded zip all matched ({new['date']}, "
            f"Integrate dreamail-openpgp workflow), and CI passed with it, UI tests included. "
            f"The previous pin, `v{old['version']}`, was commit `{old['commit']}`, checksum "
            f"`{old['checksum']}`.")
    note = textwrap.fill(note, width=76, break_on_hyphens=False) + "\n\n"
    first = text.find("Recorded for `v")
    if first < 0:
        raise Failure("docs/DEPENDENCIES.md: no `Recorded for` note to put the new one before")
    return dependencies[:start] + text[:first] + note + text[first:] + dependencies[end:]


def edit_changelog(text: str, version: str, pgp: str) -> str:
    entry = textwrap.fill(f"- The OpenPGP library moves to v{version} (rPGP `pgp` {pgp}); "
                          "docs/DEPENDENCIES.md has the pin and its checks.",
                          width=76, subsequent_indent="  ", break_on_hyphens=False) + "\n"
    return sub_once(r"^(## \[Unreleased\]\n\n)", rf"\g<1>{entry}", text, "[Unreleased] heading")


# Main -----------------------------------------------------------------------

def outputs(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    lines = "".join(f"{key}={value}\n" for key, value in values.items())
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(lines)
    print(lines, end="")


def main(argv: list[str]) -> int:
    if len(argv) > 1 or (argv and not SEMVER.match(argv[0])):
        print("usage: integrate-openpgp.py [MAJOR.MINOR.PATCH]", file=sys.stderr)
        return 2
    project = PROJECT.read_text(encoding="utf-8")
    dependencies = DEPENDENCIES.read_text(encoding="utf-8")
    pinned = current_pin(project)
    old_version = current_release(dependencies)

    tags = release_tags()
    version = argv[0] if argv else (tags[-1] if tags else "")
    if version not in tags:
        raise Failure(f"dreamail-openpgp has no release tag v{version}")
    if version_key(version) < version_key(old_version):
        print(f"v{version} is older than the pinned v{old_version}: not downgrading.", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as tmp:
        clone = Path(tmp) / "openpgp"
        git("clone", "--quiet", "--filter=blob:none", "--no-checkout", UPSTREAM, str(clone))
        commit = pinning_commit(clone, version)
        if commit == pinned:
            print(f"v{version} (commit {commit}) is already pinned: nothing to do.")
            outputs(changed="false")
            return 0
        _, checksum = package_fields(git("show", f"{commit}:Package.swift", cwd=clone))
        old_checksum = package_fields(git("show", f"{pinned}:Package.swift", cwd=clone))[1]
        facts = library_facts(clone, commit)

    base = f"{UPSTREAM}/releases/download/v{version}/{ASSET}"
    asset_sum = download(base + ".sha256").decode().split()[0]
    zip_sum = hashlib.sha256(download(base)).hexdigest()
    if not checksum == asset_sum == zip_sum:
        raise Failure(f"checksums disagree: Package.swift {checksum}, .sha256 asset {asset_sum}, "
                      f"downloaded zip {zip_sum}")
    print(f"v{version}: commit {commit}, SHA-256 {checksum} (Package.swift, asset and zip agree)")

    today = datetime.date.today()
    new = {"version": version, "commit": commit, "checksum": checksum,
           "date": f"{today.day} {today:%B %Y}", **facts}
    old = {"version": old_version, "commit": pinned, "checksum": old_checksum}
    was, now = table_advisories(dependencies), facts["advisories"]

    # Every edit is made before any file is written: a failure leaves none.
    edited = {
        PROJECT: edit_project(project, version, commit),
        DEPENDENCIES: edit_dependencies(dependencies, old, new),
        CHANGELOG: edit_changelog(CHANGELOG.read_text(encoding="utf-8"), version, facts["pgp"]),
    }
    for path, text in edited.items():
        path.write_text(text, encoding="utf-8")

    review = was != now
    body = [
        f"Integrates dreamail-openpgp [v{version}]({UPSTREAM}/releases/tag/v{version}) "
        f"(rPGP `pgp` {facts['pgp']}, {facts['crates']} crates), replacing v{old_version}.",
        "",
        f"- Commit pinned: `{commit}` ({UPSTREAM}/commit/{commit})",
        f"- SHA-256 `{checksum}`: the same in Package.swift, the release's `.sha256` asset and the downloaded zip.",
        f"- Changes since v{old_version}: {UPSTREAM}/compare/{pinned}...{commit}",
        "",
        "Regression check: the full CI workflow (workflow hardening, package pins, build with warnings "
        "as errors, unit tests including the linked-library tests, test-skip check, both UI shards) "
        "ran on this branch with only this pin changed, after CI was green on main.",
    ]
    if review:
        body += ["", "**Needs a person:** the accepted advisories changed "
                 f"(table: {', '.join(was) or 'none'}; library: {', '.join(now) or 'none'}). "
                 "Update the row and DEC-051 in docs/registro-decisioni.md before merging."]
    BODY.parent.mkdir(exist_ok=True)
    BODY.write_text("\n".join(body) + "\n", encoding="utf-8")
    outputs(changed="true", version=version, commit=commit, review=str(review).lower())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(1)
