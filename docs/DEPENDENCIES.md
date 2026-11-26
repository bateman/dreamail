# Dependencies and provenance

DreaMail has two third-party packages (GRDB below, and the OpenPGP library in
its own section), each pinned in `project.yml` by full commit
SHA rather than by tag, because a tag can be moved after the fact and the
generated Xcode project (git-ignored) carries no committed lock file. The
table below is the bill of materials at the scale the project needs
(finding F-10). It is a record: the only enforced value is the `revision:`
in `project.yml`.

| | |
|---|---|
| Package | GRDB.swift, DuckDuckGo build with SQLCipher |
| Upstream | <https://github.com/duckduckgo/GRDB.swift> |
| Package tag | `3.0.0` (GRDB 7.4.1, SQLCipher 4.7.0), a lightweight tag on a commit dated 28 March 2025 |
| Commit (`revision:` in `project.yml`) | `46098847eeabdb008f238bef5750a8e64097b6ed` |
| Binary | `GRDB.xcframework.zip` from the `3.0.0` GitHub release, declared as a SwiftPM `binaryTarget` |
| Binary SHA-256 (declared in `Package.swift` at that commit) | `41f01022f6a35986393e063e1ef386fd896646ed032f7d0419c4b02fa3afe61d` |
| Recorded | 24 November 2026: commit from `git ls-remote`, checksum read from `Package.swift` at the commit, and the downloaded zip's SHA-256 matched it |
| Licence, GRDB | MIT (Gwendal Roué), [upstream LICENSE](https://github.com/groue/GRDB.swift/blob/v7.4.1/LICENSE) |
| Licence, SQLCipher | BSD 3-Clause (Zetetic LLC), [upstream LICENSE.md](https://github.com/sqlcipher/sqlcipher/blob/v4.7.0/LICENSE.md); SQLCipher is built on SQLite, which is in the public domain |
| Licence, packaging repo | none stated: the DuckDuckGo repository has no licence file and contains only the manifest and release scripts |

The xcframework is trusted as DuckDuckGo published it: it has not been
rebuilt from source or compared with an independent build. Both MIT and
BSD 3-Clause require their notices in redistributed binaries; how a public
release ships them is the owner's decision at distribution time.

## OpenPGP library

| | |
|---|---|
| Package | `DreaMailRPGP`, the project's own OpenPGP engine over rPGP |
| Upstream | <https://github.com/bateman/dreamail-openpgp> |
| Release | `v0.2.0` |
| Commit (`revision:` in `project.yml`) | `b87eb51e7a4faf34c0f5d868342c1de772d49ac9` |
| Binary | `DreaMailRPGP.xcframework.zip` from the `v0.2.0` GitHub release, a static library declared as a SwiftPM `binaryTarget`; built twice by the library's Release workflow and published only if both builds are identical |
| Binary SHA-256 (declared in `Package.swift` at that commit) | `bcde125bcc1d97e89562a771ea85b6e9a6f3e2ca16204396f8838223edda5839` |
| Recorded | 25 November 2026 |
| Contents | rPGP (`pgp` =0.21.1, MIT OR Apache-2.0) and 145 crates in all, listed with their licences in the library's `THIRD_PARTY_LICENSES.md`, which ships in the app. `cx448` has no licence text; its algorithms are refused by policy but the code is compiled in |
| Accepted advisories (DEC-051) | RUSTSEC-2023-0071 (`rsa`, Marvin), RUSTSEC-2026-0387 (`crypto-bigint`) |
| Linked when | always, also with `DREAMAIL_PGP` off (DEC-060); with the switch off no code path reaches it |

Recorded for `v0.2.0`: the checksum in `Package.swift` at the commit, the
release's `.sha256` asset and the SHA-256 of the downloaded zip all matched
(25 November 2026). `v0.2.0` only renames the library for DreaMail (DEC-065):
module `DreaMailRPGP`, header `dreamail_rpgp.h`, symbols `dm_pgp_*`, types
`DMResult` and `DMBuffer`, crate `dreamail-rpgp`; the crates and their
versions are those of `v0.1.1`. Earlier pins: `v0.1.1` (decryption of GnuPG
2.4's OCB messages) was commit `4c66295af3b5e88fb5e593b48059f7fc2dcbe6b7`,
checksum `441e553914f89dc6565fddc1abd5bf643ec172d5115733914959400e3f78dd3b`;
`v0.1.0` was commit `adad8a18d07c0ec10695e43bb700479d0d971dfa`.

To move to a new release, run the **Integrate dreamail-openpgp** workflow
(Actions, manual only; empty version: the newest release). It first needs
the whole CI, UI shards included, green on `main` (a manual run there,
reused if one already passed). `.github/scripts/integrate-openpgp.py` then
checks that the release's tag commit lies between the current pin and the
new one on the library's `main`, and that `Package.swift` at the new commit,
the release's `.sha256` asset and the downloaded zip agree. The workflow
then verifies the zip's build provenance attestation (`gh attestation
verify`): signed by the library's `release.yml` running on `refs/heads/main`,
from that tag commit, on a GitHub-hosted runner (releases up to `v0.2.0`
have none). It updates `project.yml`,
this table and `CHANGELOG.md`, and runs the whole CI again on branch
`deps/dreamail-openpgp-v<version>`, where only the pin changed. Green: the
pull request is merged, unless the run's `merge` input is off. Red: it stays
a draft with the failed run. It always waits for a person when
`Package.swift` changed beyond its version and checksum, when the library's
build, check or release pipeline was touched by any commit between the
two pins (`.github`, `scripts`, `.cargo`, `rust/.cargo`, `rust/deny.toml`,
the toolchain files), or when the accepted advisories differ from this
table (DEC-051 must be updated with them).

## What enforces what

1. **The revision pin fixes the manifest.** `revision:` names one commit, so
   `Package.swift`, and the binary checksum it declares, cannot change
   without a change to `project.yml`.
2. **SwiftPM enforces the manifest's checksum on download.** It refuses a
   binary archive whose SHA-256 differs from the declared checksum.
3. **CI and release builds always download.** The unit job deletes the
   restored `build/dd.noindex/SourcePackages` before building, and
   `make release` deletes `build/ddship.noindex/SourcePackages`, so neither
   builds from a previously extracted binary. The UI job restores no cache.
   CI runners start without a SwiftPM download cache. On a developer Mac,
   `make release` may be served the archive from
   `~/Library/Caches/org.swift.swiftpm`; whether Xcode re-hashes an archive
   served from there has not been verified.
4. **A tripwire keeps the pin a pin.** `.github/scripts/check-package-pins.py`
   runs in the *Workflow hardening* job and at the start of `make release`'s
   build. It fails if a package in `project.yml` is anything other than
   `url:` plus a 40-hex `revision:`, and if `project.yml` uses `include`,
   `localPackages`, `projectReferences`, `framework:` or `carthage:`
   dependencies, or a top-level form it does not recognise. Like the
   workflow check it catches regressions in review; it is not a security
   boundary.

Local `make build` and `make test` keep their cached packages and are not
covered by point 3.

## How to upgrade

1. Pick the new release at
   <https://github.com/duckduckgo/GRDB.swift/releases> and read its notes and
   the GRDB and SQLCipher versions in its README.
2. Resolve the tag to a commit. Ask for the peeled form too: for an
   annotated tag the plain ref is the tag object, and the `^{}` line is the
   commit.
   ```sh
   git ls-remote https://github.com/duckduckgo/GRDB.swift 'refs/tags/<tag>' 'refs/tags/<tag>^{}'
   ```
3. Read the binary checksum from the manifest at that commit, download the
   release's zip, and check that they agree:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/duckduckgo/GRDB.swift/<commit>/Package.swift
   shasum -a 256 GRDB.xcframework.zip
   ```
4. In one commit, change `revision:` and its version comment in
   `project.yml` and update the table above (tag, commit, checksum, date,
   and the licences if upstream changed them).
5. Run `make test` (Xcode re-resolves the package) and let CI build it. Then
   retest database encryption by hand: open an existing encrypted database
   with the new build.
