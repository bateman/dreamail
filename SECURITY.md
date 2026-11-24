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

## Remote images

Remote HTTPS images load by default when a message is opened (Settings →
Appearance → Load remote images: Always; Ask each time and VIP senders are
stricter). Mail in Spam and conversations that were not opened (including
neighbour pre-render) never load them without a click. With images allowed,
these risks remain:

- **Open tracking.** The sender's servers learn when the message was opened,
  the IP address (approximate location and network) and client details
  (WebKit User-Agent, language). Moving to a message in the list with the
  reading pane showing, and auto-advance after archive or delete, count as
  opening it. Holding an arrow key opens only the row where the key stops.
- **What loads.** Everything the CSP `img-src data: cid: https:` admits:
  `<img>`, `srcset` and `<picture>` sources, CSS `url()` images (backgrounds,
  list markers, borders), `<input type=image>`, `<video poster>`, and SVG
  `<image>`. Nothing else (no scripts, fonts, frames, media, fetches).
- **Fingerprinting without scripts.** Images chosen by CSS media queries,
  `srcset` widths, `:hover` and animations can report window size, pixel
  density, dark mode and some interaction back to the sender.
- **Cookies** set by image responses stay in a non-persistent store and do
  not cross messages or app runs.
- **Private-network requests.** An image URL can point at an HTTPS host on
  the local network; WebKit sends a blind GET (no response is readable by the
  message, but the request itself happens).
- **Decoding attacker-served images** happens without a click, so an image
  decoder bug in macOS is reachable by opening the message.
- **Spam is the only gate.** Gmail's phishing and suspicious-sender warnings
  are not exposed by its API, so only the `SPAM` label (on the message, or on
  the thread after you mark it) blocks loading. Trash follows the policy.
- **Label lag.** Mail Gmail moves to Spam later loads under the policy until
  the next sync brings the label.

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
account removed), this is what happens to it:

- **The database file: overwritten.** SQLite's `secure_delete` is on for
  every connection (SQLCipher also forces it on every keyed connection), so a
  deleted row is zeroed in its page and a freed page is zeroed before it
  joins the freelist. Freed pages are then truncated off the end of the file
  in batches (`auto_vacuum = INCREMENTAL`).
- **The full-text index: overwritten.** FTS5's `secure-delete` removes a
  deleted message's terms from the index at delete time. A bulk delete
  rebuilds the index from the remaining messages instead, which leaves no
  deleted term either.
- **The write-ahead log: truncated.** Page images from before a delete stay
  in the `-wal` file until a checkpoint truncates it. A truncating
  checkpoint runs about five seconds after any committed deletion, at every
  open, at quit, and otherwise once the log has gone five minutes without a
  truncation (checked after each sync pass and every five minutes).
- **Outside the database: deleted (unlinked), not overwritten.** The
  attachment copies of a message that is gone, and the notifications of a
  thread with no message left, are removed when the deletion is processed:
  a few seconds after it, or at quit. The ids of deleted messages wait in a
  small queue inside the encrypted database until then. Google API
  responses are never written to the on-disk HTTP cache, and the cache file
  earlier builds wrote is deleted.

The limits, stated plainly:

- **Storage hardware and APFS.** Overwriting a page or deleting a file does
  not guarantee that the old physical blocks are erased. APFS is
  copy-on-write and SSD controllers remap blocks (wear levelling), so old
  blocks can remain on the device until reused. MishMail does not attempt
  "secure erase" loops, which cannot work there. Those blocks are protected
  only if FileVault is on; the database's blocks are also encrypted with the
  SQLCipher key, the attachment copies' and notifications' are not.
- **Snapshots and backups.** Local APFS snapshots, Time Machine and any
  other backup of the app's container keep what the files held when they
  were taken. The database in them is encrypted under the key in the
  Keychain; attachment copies in the temporary folder are not.
- **Copies outside MishMail's files.** Swap, crash reports and the system's
  unified log can hold what the app had in memory or logged; MishMail logs
  no mail content, and its diagnostic log redacts it, but it cannot reach
  what the operating system keeps. Quick Look thumbnails, and any file
  handed to or saved by another app, are outside MishMail's reach.
- **Attachment copies of mail that is not deleted** stay in the temporary
  folder, unencrypted, until their message or account goes (or the system
  clears the temporary folder).
- **Short residue in the database.** A cell that SQLite moves during a
  b-tree rebalance is not zeroed at its old position until that page is
  rewritten. FTS5's segment index (`message_fts_idx`) can keep a short
  prefix of a deleted term as a separator key until its leaf empties or the
  index is rebuilt.
- **The time window.** Deleted content can stay in the WAL for about five
  seconds, longer while a reader holds the log (the scrub retries, then
  waits for readers), and until the next open after a crash. An updated
  row's earlier versions (text cleared from a draft) stay in the WAL for up
  to about ten minutes. Attachment copies and notifications stay until the
  deletion is processed (seconds), or until the next launch if the app is
  killed first.
- **Recent searches** are kept apart from the mail and cleared only when an
  account is removed.
- **A cache still waiting for encryption.** While a cache from before
  encryption waits for its one-time conversion (another copy of MishMail
  holds it), the whole cache is unencrypted and read-only: nothing in it can
  be deleted until it is converted.
- **Files kept on purpose.** When the cache cannot be opened and is reset,
  the old file is kept aside as `mail.sqlite.unreadable`, because it may be
  the only copy of unsent drafts or scheduled sends. An encrypted one is
  kept as it is. An unencrypted one (a damaged cache from before
  encryption) is copied into an encrypted file and then deleted, but only
  when the copy is provably complete: if the file fails its integrity check,
  or any table cannot be read, it is kept as it was, unencrypted.
- **Before this version.** The pre-encryption plaintext file was replaced
  by `rename(2)`, which frees its blocks without overwriting them.
