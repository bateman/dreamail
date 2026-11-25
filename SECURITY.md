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
neighbour pre-render) never load them without a click.

Opening a message means showing its body: a click on its row, the `n` and
`p` keys (they open the message they move to) and `;` (expand all). One `;`
opens every message of the conversation, so under "Always" it loads the
remote images of all of them at once.

**Cached per message.** The first time a message is opened with its remote
images allowed, it shows them exactly as before (WebKit loads them live),
and MishMail's own client downloads each cacheable image of that message in
the background and keeps it in the encrypted database with the message (see
"What deleting means"). On that first open the sender therefore sees two
requests per image: one from WebKit, one from the app's client, which is
distinguishable from WebKit (WebKit downloads in its own process and the
app cannot read those bytes). What later opens do depends on whether every
cacheable image of the message is settled, that is stored, or refused and
remembered as refused:

- **All settled:** later opens, after a relaunch too, show the message from
  the cache with no request for the stored images. Images the app refused
  (an empty or 204 answer, SVG, an oversized image, an image past the
  message's 2.5 MiB, a server error other than a temporary one) are
  remembered with the message as refused (their URL digest only) and load
  live from WebKit on every open, as do images in positions the app does not
  rewrite (`<picture>`, `image-set()`, CSS escapes, a 41st image).
- **Not all settled** (an image failed for a network reason: offline, a
  timeout, DNS, a 5xx, 408 or 429 answer): the message opens entirely live
  again, so WebKit asks the sender for every image again, and the app's
  client tries the missing ones again, on every open until they settle.

This reduces repeat requests for ordinary images; it is not a defence
against tracking: a sender can keep an image uncacheable, or keep a message
from settling, and is then asked on every open.
Nothing is downloaded for mail that is not open, nor for a message whose
images the policy blocks (Ask each time without a click, non-VIP senders,
Spam): the cache never overrides the decision, and the neighbour pre-render
and prefetch only read what is already cached. The app's client:

- requests `https:` URLs only, on the default port, with a fixed `Accept`,
  `Accept-Language` and WebKit-shaped `User-Agent`, and no cookies, cache,
  credentials or `Referer`;
- follows at most 3 redirects, each re-checked against the same rules;
- refuses `localhost`, `.local`/`.internal`/single-label names, literal
  private, loopback, link-local, CGNAT or unique-local addresses, and names
  whose DNS answer includes one. Not caught: a DNS answer that changes
  between that check and the connection, and a system proxy or PAC file,
  which resolves and connects for the app, so the check does not govern the
  destination there;
- keeps at most 2 MiB per image (enforced while streaming), 2.5 MiB and 40
  images per message, at most 6 requests at a time app-wide, raster images
  only (JPEG, PNG, GIF, WebP; animated GIF stored as served), never SVG.
- checks the leading bytes against those four formats before anything else,
  then lets ImageIO read the image's header (no pixel decode) in the app
  process. This is new attack surface in the app process for those four
  parsers' header code; every other format is rejected before ImageIO sees
  it. Decoding stays WebKit's, as before.

What is cached: `<img>` images (with a `srcset`, the one candidate the app
picks, kept with its density so Retina sharpness and size do not change;
otherwise `src`), `background` attributes, and CSS `url()` images in `style`
attributes and `<style>` blocks. What still loads live from WebKit when
allowed, exactly as before: `<picture>` sources, `<video poster>`,
`<input type=image>`, SVG `<image>`, `image-set()`, CSS written with
escapes, images beyond the caps, anything the client refuses (remembered
with the message, never asked again by the app) and anything it could not
fetch for a network reason (asked again on the next open). A URL is stored
only as its SHA-256, for images and refusals alike.

With images allowed, these risks remain:

- **Open tracking.** The sender's servers learn when the message was first
  opened (later opens of a cached message send nothing), the IP address
  (approximate location and network) and client details (a WebKit-shaped
  User-Agent; WebKit's own for images that still load live). Moving to a message in the list with the
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
  message, but the request itself happens). The app's own client refuses
  such hosts, so those images are left to WebKit as before.
- **Decoding and storing attacker-served bytes.** Cached images are the
  sender's bytes, stored as served after an ImageIO header check (no
  re-encoding), and decoded by WebKit on every open, as before.
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

## Google Calendar (off in this build)

The Calendar integration is being designed and is compiled in only when the
build sets `MISHMAIL_CALENDAR = YES` (empty in `Config/Signing.xcconfig`;
`make install` and `make release` take the tracked value). With it off:

- **No new network destination.** Nothing reaches the Calendar API
  (`https://www.googleapis.com/calendar/v3/`); its one network path refuses
  before sending, and the tests check it.
- **No new scope.** The Gmail sign-in never asks for a Calendar scope.

With it on, Calendar is a **separate consent**, asked for only when the user
connects Calendar for an account: desktop apps cannot extend an existing
grant, so it has its own refresh token in the Keychain
(`calendarRefreshToken.<account>`). The token is kept only when Google says
it belongs to that same account.

- **Scope (owner's decision, DEC-048):** `calendar.events` (read and change
  events on every calendar the user can access, shared ones included, so a
  conflict on a shared calendar can show its title), plus
  `calendar.events.freebusy` and `calendar.calendarlist.readonly`. MishMail
  changes an event only to write the user's own answer or to add an
  invitation the user chose to add.
- **Stored:** only the grant and the calendars the user chose (the primary
  one by default). Encrypted, deleted with the account or when Calendar is
  disconnected, under the rules below. No event is stored: availability and
  where an invitation's event is in Google Calendar are computed in memory.
- **Answers:** the iTIP e-mail is always sent. The answer is also written on
  the user's calendar (with Google asked to notify nobody) only when Google's
  event has the invitation's UID, organizer *and* time, so a forged
  invitation that copies a real event's UID cannot change that event.
- **No revocation at Google.** Disconnecting Calendar, removing an account or
  refusing a consent given for another account deletes the token and the
  grant here, but does not revoke them at Google: revoking a token can also
  revoke the Gmail access of the same OAuth client. The user removes the
  grant in their Google account (Security → Third-party access).

## What deleting means

When mail leaves MishMail's local cache (a message deleted or trashed and
purged, local mail pruned, a draft discarded, a chat or summary cleared, an
account removed, a cached inline or remote image evicted), this is what
happens to it:

- **The database file: overwritten.** SQLite's `secure_delete` is on for
  every connection (SQLCipher also forces it on every keyed connection), so a
  deleted row is zeroed in its page and a freed page is zeroed before it
  joins the freelist. Freed pages are then truncated off the end of the file
  in batches (`auto_vacuum = INCREMENTAL`).
- **Cached inline images: inside the database, deleted with their mail.**
  The images a message's HTML embeds as `cid:` parts (raster images only,
  never SVG) are kept in the
  encrypted database once they have been downloaded, so the conversation
  opens with them later, after a relaunch too. Each image is tied to its
  message, attachment part and account, and to the exact body it was
  resolved from. It goes with its message: a deletion, a local prune, the
  deletion of its thread, or a re-fetch that changes the message's content
  (all through the database's cascading deletes), and with its account
  (removal also deletes them by name); the same overwrite and log
  truncation apply. The cache holds at most 200 MiB (3 MiB of images per
  message); beyond that the least recently used messages' images are
  deleted, the same way. The cache itself writes nothing outside the
  database (no on-disk HTTP cache, no temporary file); the same image
  opened as an attachment or in Quick Look is a copy in the temporary
  folder, as described below.
- **Cached remote images: inside the database, deleted with their mail.**
  The https images of a message opened with remote images allowed (see
  "Remote images") are kept in the encrypted database, one copy per message
  (the same image in two messages is stored twice, so nothing is shared
  across messages or accounts), keyed by the SHA-256 of the URL, never the
  URL itself; so are the refusal markers (the digest of an image the app
  will not fetch again for that message). They go with their message (deletion, local prune, thread
  deletion, through the cascading deletes) and with their account (removal
  also deletes them by name), under the same overwrite and log truncation.
  This cache holds at most 200 MiB of its own (apart from the inline images'
  200 MiB) and 2.5 MiB per message; beyond that the least recently used
  messages' images are deleted. Nothing is written outside the database (no
  HTTP cache, no temporary file); the app's client uses an ephemeral session
  with no disk cache.
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
