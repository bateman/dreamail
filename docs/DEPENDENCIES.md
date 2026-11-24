# Dependencies and provenance

MishMail has one third-party package. It is pinned by commit, not by tag,
because a tag can be moved after the fact and the generated Xcode project
(git-ignored) carries no committed lock file. This table is the bill of
materials at the scale the project needs (finding F-10).

| | |
|---|---|
| Package | GRDB.swift, DuckDuckGo build with SQLCipher |
| Upstream | <https://github.com/duckduckgo/GRDB.swift> |
| Package tag | `3.0.0` (GRDB 7.4.1, SQLCipher 4.7.0), tagged 28 March 2025 |
| Commit | `46098847eeabdb008f238bef5750a8e64097b6ed` |
| Binary | `GRDB.xcframework.zip` from the `3.0.0` GitHub release, declared as a SwiftPM `binaryTarget` |
| Binary SHA-256 | `41f01022f6a35986393e063e1ef386fd896646ed032f7d0419c4b02fa3afe61d` |
| Licence, GRDB | MIT (Gwendal Roué), [upstream LICENSE](https://github.com/groue/GRDB.swift/blob/v7.4.1/LICENSE) |
| Licence, SQLCipher | BSD 3-Clause (Zetetic LLC), [upstream LICENSE.md](https://github.com/sqlcipher/sqlcipher/blob/v4.7.0/LICENSE.md); SQLCipher is built on SQLite, which is in the public domain |
| Licence, packaging repo | none stated: the DuckDuckGo repository has no licence file and contains only the manifest and release scripts |

The xcframework is a prebuilt binary: its contents have not been rebuilt
from source or compared with an independent build. What is verified is that
the zip matches the checksum DuckDuckGo published in the manifest at that
commit. Both BSD 3-Clause and MIT require their notices in redistributed
binaries, so a public MishMail release should ship them (for example in the
About panel or a bundled notices file).

## How it is enforced

- `project.yml` names the package by `url` and `revision` only.
- [`.github/package-pins.txt`](../.github/package-pins.txt) records the URL,
  commit and binary checksum.
- `check-package-pins.py` in the *Workflow hardening* job fails if
  `project.yml` uses a version or branch rule, or its URL or revision differs
  from the pins.
- `check-package-pins.py --resolved build/dd.noindex` in the unit job runs
  after the build and fails unless the SwiftPM checkout and the generated
  `Package.resolved` are at the pinned commit and the checkout's
  `Package.swift` declares exactly the pinned checksum. SwiftPM refuses a
  downloaded binary whose SHA-256 differs from the manifest's, so the binary
  that was built is the one with the recorded checksum.
- The build cache key hashes `project.yml`, so a new pin never reuses a
  cached checkout of the old one.

## How to upgrade

1. Pick the new release at
   <https://github.com/duckduckgo/GRDB.swift/releases> and read its notes and
   the GRDB and SQLCipher versions in its README.
2. Resolve the tag to a commit, and read the checksum from the manifest at
   that commit:
   ```sh
   git ls-remote https://github.com/duckduckgo/GRDB.swift refs/tags/<tag>
   curl -fsSL https://raw.githubusercontent.com/duckduckgo/GRDB.swift/<commit>/Package.swift
   ```
3. Download the release's `GRDB.xcframework.zip` and check that
   `shasum -a 256 GRDB.xcframework.zip` prints the manifest's checksum.
4. In one commit, change `revision:` and the version comment in
   `project.yml`, the `revision` and `checksum` lines in
   `.github/package-pins.txt`, and the table above (licences included, if the
   upstream licences changed).
5. Run `make test` locally (Xcode re-resolves the package) and let CI confirm
   the pins. Database encryption is the part to retest by hand: open an
   existing encrypted database with the new build.
