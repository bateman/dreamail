# mishmail-rpgp

C ABI over [rPGP](https://github.com/rpgp/rpgp) for MishMail's OpenPGP
engine (step 4B, scope B: verify signatures, decrypt, read keys). The Swift
side is `Sources/MishMail/PGP/RPGPEngine.swift`; the interface is
`include/mishmail_rpgp.h`.

**Not linked into the app yet.** The xcframework, its pin and its place in
`project.yml` wait for the owner's decision on the library (see the pull
request). Everything stays behind the `MISHMAIL_PGP` build switch, which is
off.

## What is pinned

| | |
|---|---|
| rPGP | crate `pgp` `=0.21.1` (crates.io, 11 November 2026), licence MIT OR Apache-2.0 |
| rPGP crate checksum (crates.io, also in `Cargo.lock`) | `c7275cbf21850789239e1be05d9a887e6bba6aa8085a81be09ca021c8379baef` |
| rPGP git tag `v0.21.1` | tag object `953a14294011e564ff2444f8b8574cdfba8d19de`, commit `56a40045e1d7516e5ec02244ea2884c92bece45f` |
| Every other crate | `Cargo.lock`, used with `--locked`: version and SHA-256 per crate, 148 crates in the dependency tree, all under permissive licences (MIT, Apache-2.0, BSD-2/3, Zlib, Unlicense, Unicode-3.0); no C code is compiled |
| Rust compiler | `rust-toolchain.toml`: 1.97.0 (rPGP needs 1.88 or later) |
| Default features | off (`default-features = false`: no bzip2) |

Recorded 25 November 2026: version, date, licence and checksum from the
crates.io API; tag and commit from `git ls-remote`; licences of the tree from
`cargo metadata --locked`.

## Design

- Stateless: every call receives the certificates, secret keys and passphrase
  it may use. Storage (Keychain, encrypted database) is the app's.
- Results are JSON without message text or key material. Plaintext travels
  in a separate buffer that `mm_pgp_free` zeroes before freeing.
- A panic is caught at the boundary and reported as `internal`.
- rPGP leaves certificate policy to the application. The policy here
  (`cert_state` in `src/engine.rs`) is strict:
  - every self-signature must verify and at least one user ID must be
    bound; third-party certifications are ignored (rPGP's `verify_bindings`
    would reject a key that carries one);
  - a user ID revoked by its owner is not listed;
  - any key revocation by the primary key means revoked;
  - the newest self-signature decides expiry, judged at the time of the
    check, not at the time of signing;
  - a signing subkey needs a verifying binding that allows signing, and no
    subkey revocation.
- Decryption uses rPGP's defaults: legacy SED (no integrity check) is
  refused; SEIPD v1 is MDC-checked before any plaintext is released; SEIPD v2
  is AEAD.

## Build and test

```sh
cargo test --locked                        # any platform; CI job "OpenPGP engine (Rust)"
scripts/build-rpgp-xcframework.sh          # macOS: xcframework zip and its SHA-256
```
