# Security Policy

MishMail is a local-first mail client that handles OAuth tokens and renders
untrusted email. Security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use
GitHub's **private vulnerability reporting** (Security → Report a vulnerability)
or email the maintainer directly. Include:

- what the issue is and where in the code,
- a proof-of-concept or reproduction if you have one,
- the impact you think it has.

You'll get an acknowledgement as soon as possible.

## Scope

Especially interesting:

- HTML-email rendering escapes (navigation, remote content, local-file access),
- OAuth/PKCE or loopback-listener weaknesses,
- Keychain/token exposure,
- SQL injection or path traversal,
- attachment handling.

## Design notes

The threat model and mitigations are summarized in the
[Security section of the README](README.md#security).

A 2026-07 source review (findings SEC-001–003, all fixed) lives in
[docs/security-review.md](docs/security-review.md); a second pass later that
month (SEC-004–007, all fixed) lives in
[docs/security-review-2026-07-29.md](docs/security-review-2026-07-29.md).
## What deleting means

When mail leaves MishMail's local cache (a message deleted or trashed and
purged, local mail pruned, a draft discarded, a chat or summary cleared, an
account removed), the content is overwritten, not just unlinked, in every
file MishMail keeps:

- **The database file.** SQLite's `secure_delete` is on for every
  connection (SQLCipher also forces it on every keyed connection), so a
  deleted row is zeroed in its page and a freed page is zeroed before it
  joins the freelist. Freed pages are then truncated off the end of the file
  in batches (`auto_vacuum = INCREMENTAL`).
- **The full-text index.** FTS5's `secure-delete` removes a deleted
  message's terms from the index at delete time. A bulk delete rebuilds the
  index from the remaining messages instead, which leaves no deleted term
  either.
- **The write-ahead log.** Page images from before a delete stay in the
  `-wal` file until a checkpoint truncates it. A truncating checkpoint runs
  about five seconds after any committed deletion, at every open, after a
  sync pass when the log has not been truncated for five minutes, and at
  quit.
- **Outside the database.** Attachment copies opened from a deleted
  message, and the notifications of its thread, are removed after the
  deletion; Google API responses are never written to the on-disk HTTP
  cache.

The limits, stated plainly:

- **Storage hardware and APFS.** Overwriting a page or deleting a file does
  not guarantee that the old physical blocks are erased. APFS is
  copy-on-write and SSD controllers remap blocks (wear levelling), so old
  blocks can remain on the device until reused. MishMail does not attempt
  "secure erase" loops, which cannot work there. FileVault protects those
  blocks; the database's are also encrypted with the SQLCipher key.
- **Snapshots and backups.** Local APFS snapshots, Time Machine and any
  other backup of the app's container keep what the files held when they
  were taken. The database in them is encrypted under the key in the
  Keychain; attachment copies in the temporary folder, and any cache from
  before encryption, are not.
- **Memory and the system.** Swap, crash reports, and the system's unified
  log can hold what the app had in memory or logged. MishMail logs no mail
  content, and its diagnostic log redacts it, but it cannot reach what the
  operating system keeps.
- **Short residue in the database.** A cell that SQLite moves during a
  b-tree rebalance is not zeroed at its old position until that page is
  rewritten. FTS5's segment index (`message_fts_idx`) can keep a short
  prefix of a deleted term as a separator key until its leaf empties or the
  index is rebuilt.
- **The time window.** Deleted content can stay in the WAL for about five
  seconds, longer while a reader holds the log (the scrub retries, then
  waits for readers), and until the next open after a crash. An updated
  row's earlier versions (text cleared from a draft) stay in the WAL until
  the next truncation: a deletion, the five-minute check after a sync pass,
  or quit.
- **Recent searches** are kept apart from the mail and cleared only when an
  account is removed.
- **Files kept on purpose.** When the cache cannot be opened and is reset,
  the old file is kept aside as `mail.sqlite.unreadable`, encrypted, because
  it may be the only copy of unsent drafts or scheduled sends. A damaged
  cache from before encryption that cannot be read at all is kept as it
  was, unencrypted, for the same reason.
- **Before this version.** The pre-encryption plaintext file was replaced
  by `rename(2)`, which frees its blocks without overwriting them, and
  earlier builds could leave Gmail responses in the HTTP cache file, which
  is now deleted.
