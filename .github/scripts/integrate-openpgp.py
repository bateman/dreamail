#!/usr/bin/env python3
"""Prepares the integration of a dreamail-openpgp release: the edits the
Integrate dreamail-openpgp workflow commits on its branch, after checking the
release (docs/DEPENDENCIES.md, "OpenPGP library").

  1. Picks the release: the version given, or the newest vX.Y.Z tag of
     dreamail-openpgp. A downgrade is refused.
  2. Finds the commit on its main whose Package.swift points at that
     release (the commit DreaMail pins), and reads from it the checksum, the
     rPGP version and licence, the crate count and the accepted advisories.
  3. Checks that the release's tag commit lies between the current pin and
     that commit on main's history, and that the checksum in Package.swift, the release's .sha256 asset and
     the SHA-256 of the downloaded zip agree.
  4. Edits project.yml (revision and its version comment),
     docs/DEPENDENCIES.md (table and a "Recorded for" note) and CHANGELOG.md.
  5. Saves the zip to build/openpgp/ for the workflow, which verifies its
     build provenance attestation (gh attestation verify) before pushing.
  6. Writes the pull request body to build/openpgp-integration.md and, under
     GitHub Actions, the outputs (changed, version, commit, built, review).

`review=true` means a change needs a person, and the workflow does not
merge: Package.swift changed beyond its version and checksum, the library's
build, check or release pipeline changed (PIPELINE), or the accepted
advisories (DEC-051) differ from the table's.

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
import tomllib
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
UPSTREAM = "https://github.com/bateman/dreamail-openpgp"
ASSET = "DreaMailRPGP.xcframework.zip"
PROJECT = REPO / "project.yml"
DEPENDENCIES = REPO / "docs" / "DEPENDENCIES.md"
CHANGELOG = REPO / "CHANGELOG.md"
BODY = REPO / "build" / "openpgp-integration.md"
# The downloaded zip, kept for the workflow's attestation check.
ZIP = REPO / "build" / "openpgp" / ASSET
# ASCII digits only: \d would also take other scripts' digits.
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
# What an rPGP licence expression may contain; anything else is refused
# before it reaches a document or the pull request body.
LICENCE = re.compile(r"^[A-Za-z0-9.+() -]+$")
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
        match = re.fullmatch(r"refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)", ref)
        if match:
            tags.append(match.group(1))
    return sorted(tags, key=version_key)


def package_fields(manifest: str) -> tuple[str, str]:
    version = re.search(r'^let version = "([^"]+)"$', manifest, re.M)
    checksum = re.search(r'^let checksum = "([0-9a-f]{64})"$', manifest, re.M)
    if not version or not checksum:
        raise Failure("Package.swift has no plain `let version` and `let checksum`")
    return version.group(1), checksum.group(1)


def declared_version(manifest: str) -> str | None:
    match = re.search(r'^let version = "([^"]+)"', manifest, re.M)
    return match.group(1) if match else None


def pinning_commit(clone: Path, version: str, ref: str = "origin/main") -> str:
    """The commit on `ref` that set Package.swift to `version`: in the newest
    run of commits declaring it, the oldest. Later commits that touch the
    manifest without changing the version do not move the pin."""
    found = None
    for commit in git("log", "--format=%H", ref, "--", "Package.swift", cwd=clone).split():
        if declared_version(git("show", f"{commit}:Package.swift", cwd=clone)) == version:
            found = commit
        elif found:
            break
    if not found:
        raise Failure(f"no commit on dreamail-openpgp main points Package.swift at v{version} "
                      "(is its Package.swift pull request merged?)")
    return found


def manifest_shape(manifest: str) -> str:
    """The manifest without its version and checksum lines: what must not
    change for the pull request to merge by itself."""
    return re.sub(r'^let (version|checksum) = .*\n', "", manifest, flags=re.M)


def deny_advisories(text: str) -> list[str]:
    """The ignored advisories, in both forms cargo-deny accepts."""
    try:
        ignore = tomllib.loads(text).get("advisories", {}).get("ignore", [])
    except tomllib.TOMLDecodeError as error:
        raise Failure(f"rust/deny.toml does not parse: {error}") from error
    ids = sorted({entry if isinstance(entry, str) else entry.get("id", "?") for entry in ignore})
    for advisory in ids:
        # Only plain ids reach the pull request body: no text a reviewer reads.
        if not re.fullmatch(r"RUSTSEC-[0-9]{4}-[0-9]{4}", str(advisory)):
            raise Failure(f"rust/deny.toml ignores something that is not a RUSTSEC id: {advisory!r}")
    return ids


# Upstream paths whose change waits for a person: what builds, checks and
# signs the binary. The automated rPGP upgrades touch none of them.
PIPELINE = [".github", "scripts", ".cargo", "rust/.cargo", "rust/deny.toml",
            "rust/rust-toolchain.toml", "rust/rust-toolchain"]


def review_reasons(manifest: str, old_manifest: str, pipeline: list[str],
                   was: list[str], now: list[str]) -> list[str]:
    """Why the pull request must wait for a person instead of merging."""
    reasons = []
    if manifest_shape(manifest) != manifest_shape(old_manifest):
        reasons.append("Package.swift changed beyond `version` and `checksum` (products, targets or "
                       "dependencies may differ; `check-package-pins.py` does not see inside it)")
    if pipeline:
        reasons.append("the library's build, check or release pipeline changed: "
                       + ", ".join(f"`{path}`" for path in pipeline))
    if was != now:
        reasons.append(f"the accepted advisories changed (table: {', '.join(was) or 'none'}; "
                       f"library: {', '.join(now) or 'none'}): update the row and DEC-051 in "
                       "docs/registro-decisioni.md")
    return reasons


def library_facts(clone: Path, commit: str) -> dict:
    show = lambda path: git("show", f"{commit}:{path}", cwd=clone)  # noqa: E731
    pgp = re.search(r'^pgp = \{ version = "=([^"]+)"', show("rust/Cargo.toml"), re.M)
    crates = re.search(r"^(\d+) crates\.$", show("THIRD_PARTY_LICENSES.md"), re.M)
    licence = re.search(r"^\| rPGP \| crate `pgp` `=[^`]+` \([^)]*\), (.+) \|$", show("README.md"), re.M)
    if not (pgp and crates and licence):
        raise Failure("cannot read the rPGP version, crate count or licence at that commit")
    if not SEMVER.match(pgp.group(1)) or not LICENCE.match(licence.group(1)):
        raise Failure(f"unexpected rPGP version {pgp.group(1)!r} or licence {licence.group(1)!r}")
    return {
        "pgp": pgp.group(1),
        "crates": int(crates.group(1)),
        "licence": licence.group(1),
        "advisories": deny_advisories(show("rust/deny.toml")),
    }


# Editing DreaMail -----------------------------------------------------------

def sub_once(pattern: str, value: str, text: str, what: str) -> str:
    """Replaces the one match of `pattern`, which has two groups around the
    part to change, with group 1 + `value` + group 2. `value` is inserted as
    is: never read as a replacement template."""
    new, count = re.subn(pattern, lambda m: m.group(1) + value + m.group(2), text, flags=re.M)
    if count != 1:
        raise Failure(f"expected one {what}, found {count}")
    return new


def current_pin(project: str) -> str:
    match = re.search(r"^  DreaMailRPGP:\n    url: \S+\n    revision: ([0-9a-f]{40})$", project, re.M)
    if not match:
        raise Failure("project.yml: no DreaMailRPGP package with a revision")
    return match.group(1)


def edit_project(project: str, version: str, commit: str) -> str:
    project = sub_once(r"(^  DreaMailRPGP:\n    url: \S+\n    revision: )[0-9a-f]{40}()$",
                       commit, project, "DreaMailRPGP revision")
    return sub_once(r"(checksummed static xcframework\. Release )v[0-9]+\.[0-9]+\.[0-9]+(, pinned)",
                    f"v{version}", project, "release comment in project.yml")


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
    text = sub_once(r"^(\| Release \| )`v[^`]+`( \|)$", f"`v{v}`", text, "Release row")
    text = sub_once(r"^(\| Commit \(`revision:` in `project.yml`\) \| )`[0-9a-f]{40}`( \|)$",
                    f"`{new['commit']}`", text, "Commit row")
    text = sub_once(r"^(\| Binary \| `DreaMailRPGP\.xcframework\.zip` from the )`v[^`]+`( GitHub release)",
                    f"`v{v}`", text, "Binary row")
    text = sub_once(r"^(\| Binary SHA-256 \(declared in `Package.swift` at that commit\) \| )`[0-9a-f]{64}`( \|)$",
                    f"`{new['checksum']}`", text, "Binary SHA-256 row")
    text = sub_once(r"^(\| Recorded \| ).+( \|)$", new["date"], text, "Recorded row")
    text = sub_once(r"^(\| Contents \| rPGP \(`pgp` =)[^)]+(\) and )",
                    f"{new['pgp']}, {new['licence']}", text, "Contents row")
    text = sub_once(r"^(\| Contents \| rPGP \(`pgp` =[^)]+\) and )[0-9]+( crates in all)",
                    str(new["crates"]), text, "Contents crate count")
    note = (f"Recorded for `v{v}`: the checksum in `Package.swift` at the commit, the release's "
            f"`.sha256` asset and the SHA-256 of the downloaded zip all matched ({new['date']}, "
            f"Integrate dreamail-openpgp workflow). "
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
    return sub_once(r"^(## \[Unreleased\]\n\n)()", entry, text, "[Unreleased] heading")


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
        # The tag's commit, which the workflow then requires to be the source
        # commit of the zip's attestation: it lies between the old pin and
        # the new one on main's history.
        built = git("rev-parse", f"v{version}^{{commit}}", cwd=clone).strip()
        if subprocess.run(["git", "merge-base", "--is-ancestor", built, commit], cwd=clone).returncode:
            raise Failure(f"release v{version} was built from {built}, which is not in the history "
                          f"of the pinned commit {commit}")
        if commit == pinned:
            print(f"v{version} (commit {commit}) is already pinned: nothing to do.")
            outputs(changed="false")
            return 0
        if version == old_version:
            raise Failure(f"v{version} is pinned, but at {pinned}, and a later upstream commit {commit} "
                          "declares the same version: a person must look")
        if subprocess.run(["git", "merge-base", "--is-ancestor", pinned, built], cwd=clone).returncode:
            raise Failure(f"release v{version} was built from {built}, which is not after the "
                          f"current pin {pinned}")
        manifest = git("show", f"{commit}:Package.swift", cwd=clone)
        old_manifest = git("show", f"{pinned}:Package.swift", cwd=clone)
        _, checksum = package_fields(manifest)
        old_checksum = package_fields(old_manifest)[1]
        facts = library_facts(clone, commit)
        # Every commit between the pins, not the net diff: a change made for
        # the release build and reverted before the new pin still counts.
        pipeline = sorted(set(git("log", "--format=", "--name-only", f"{pinned}..{commit}",
                                  "--", *PIPELINE, cwd=clone).split()))

    base = f"{UPSTREAM}/releases/download/v{version}/{ASSET}"
    asset_sum = download(base + ".sha256").decode().split()[0]
    archive = download(base)
    zip_sum = hashlib.sha256(archive).hexdigest()
    if not checksum == asset_sum == zip_sum:
        raise Failure(f"checksums disagree: Package.swift {checksum}, .sha256 asset {asset_sum}, "
                      f"downloaded zip {zip_sum}")
    print(f"v{version}: commit {commit}, SHA-256 {checksum} (Package.swift, asset and zip agree)")
    ZIP.parent.mkdir(parents=True, exist_ok=True)
    ZIP.write_bytes(archive)

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

    reasons = review_reasons(manifest, old_manifest, pipeline, was, now)
    body = [
        f"Integrates dreamail-openpgp [v{version}]({UPSTREAM}/releases/tag/v{version}) "
        f"(rPGP `pgp` {facts['pgp']}, {facts['crates']} crates), replacing v{old_version}.",
        "",
        f"- Commit pinned: `{commit}` ({UPSTREAM}/commit/{commit})",
        f"- SHA-256 `{checksum}`: the same in Package.swift, the release's `.sha256` asset and the downloaded zip.",
        "- Build provenance: the zip's attestation verified (`gh attestation verify`): signed by "
        "dreamail-openpgp's `release.yml` running on `refs/heads/main`, from the tag's commit "
        f"`{built}`, on a GitHub-hosted runner.",
        f"- Changes since v{old_version}: {UPSTREAM}/compare/{pinned}...{commit}",
    ]
    if reasons:
        body += ["", "**Needs a person, not merged by the workflow:**", *[f"- {r}" for r in reasons]]
    BODY.parent.mkdir(exist_ok=True)
    BODY.write_text("\n".join(body) + "\n", encoding="utf-8")
    outputs(changed="true", version=version, commit=commit, built=built,
            review=str(bool(reasons)).lower())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Failure as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(1)
