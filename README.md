# DreaMail

A native, local-first Gmail client for macOS. SwiftUI, Gmail REST API, SQLite.
No DreaMail server, no telemetry. Mail stays on your Mac except calls to
Google's Gmail API. Optional AI can stay on-device (Ollama) or, if you turn it
on, send mail text to a hosted model you choose — with host consent, and with
silent auto-sort refusing cloud providers.

> **Status:** early but usable (v0.x). Built for people who want a fast,
> keyboard-driven inbox that runs entirely on their own
> hardware. Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

![DreaMail inbox](docs/screenshots/inbox.png)

| Read a conversation | Compose without leaving your inbox |
|---|---|
| ![DreaMail reading pane](docs/screenshots/reading-pane.png) | ![DreaMail composer](docs/screenshots/compose.png) |

## Try DreaMail

- **Build from source (recommended):** clone the repository, install
  `xcodegen`, then run `make demo`. The Debug app opens an isolated demo inbox.
  `make run` opens the same app with your real account and needs stable signing.
- **Binaries:** this fork publishes none; build from source. Development
  builds of the upstream project, MishMail, are on
  [ronboger/mishmail's GitHub Releases](https://github.com/ronboger/mishmail/releases/latest)
  under the upstream bundle identifier, and this fork's builds
  (`io.github.bateman.DreaMail`) never update from them.
- **Explore safely:** on first launch, choose **Try demo inbox** to browse
  fictional mail before connecting Google. Demo mode never syncs or sends.
Connecting a real inbox requires your own free Google Desktop OAuth client;
the guided setup is below. You can evaluate the entire interface first.

## Features

- **Unified multi-account inbox** — connect several Google accounts; view them
  together or scoped to one, with per-account nicknames and send-as names.
- **Saved views & live filters** — build a filtered inbox from ~18 dimensions
  (label, category, from/to/cc/bcc, subject, date, calendar-invite, read
  state…) and save it as a reusable view.
- **Keyboard-first** — archive, trash, star, snooze, reply, navigate, and a
  `Cmd-K` command palette without touching the mouse.
- **Local-first sync** — mail is cached in an encrypted SQLite database with
  FTS5 full-text search; the app is fast and works offline for cached mail.
- **Compose that gets out of the way** — recipient chips with autocomplete from
  mined contacts, Cc/Bcc, quote-on-reply, reply-all dedup, attachments, drafts
  that round-trip to Gmail, and markdown in the body (bold/italic/headings/
  lists/code/math) with shortcuts and an HTML alternative on send.
- **Scheduled send, undo send, snooze, follow-up reminders, snippets.**
  Snippets trigger with `/name` in the body, fill variables like
  `{first_name}` and `{my_first_name}`, and can move an introducer to Bcc for
  you.
- **Optional AI** — draft, summarize, triage, and Ask AI. The default is a
  local [Ollama](https://ollama.com) model (nothing is uploaded; it works in
  airplane mode). You can also attach hosted providers (Claude, ChatGPT, Grok,
  Gemini, OpenRouter, or a custom endpoint). Hosted tasks send mail text off
  this Mac only after you configure them; custom hosts need an explicit consent
  toggle; silent auto-sort never uses a cloud model.
- **Private by construction** — see [Security](#security).

## Requirements

- **macOS 14.0+**
- **Xcode 15.3+** (Swift 5.10) to build
- **[xcodegen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
- A **free Google account** and a personal OAuth client (see below)
- *(optional)* **Ollama** for on-device AI, or a hosted provider in Settings → AI

## One-time Google setup (~5 minutes)

The app uses **your own** free Google OAuth client, so no third party ever sees
your mail. (See [Why bring your own client?](#why-bring-your-own-oauth-client)
for the reasoning.)

1. Go to https://console.cloud.google.com/ and create a project (e.g. "DreaMail").
2. **APIs & Services → Library** → search "Gmail API" → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - User type: **External**, fill in app name + your email, save.
   - Under **Audience / Test users**, add every Google account you want to
     connect. (Testing mode allows up to **100** test users — plenty for
     personal use.)
   - **Testing is only for the initial setup.** Google expires refresh tokens
     after **7 days** for External apps in Testing when Gmail scopes are
     requested. Accounts connected together will therefore ask to reauthorize
     together a week later.
   - For normal daily use, switch **Publishing status → In production** when
     your Google account or Workspace policy permits it. A personal unverified
     app may still show the expected “Google hasn't verified this app” warning;
     if you keep the project in Testing, plan to reauthorize weekly.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app**.
   - Copy the **Client ID** and **Client Secret** (or download the
     `client_secret_*.json`).
5. Launch DreaMail → **Settings (Cmd-,) → Google API** → paste both.
   (Debug and Release are separate apps with separate Keychains — paste into
   whichever build you're using. Never commit client secrets; each person brings
   their own free Desktop client.)
6. Sidebar → **Add Google Account…** → your browser opens → sign in → the
   browser redirects to `http://127.0.0.1:<port>/oauth2/callback` → you should
   see **“Signed in.”** → return to DreaMail; the account appears. Repeat for
   each account.

> During sign-in Google shows a **"Google hasn't verified this app"** screen
> because it's your own unverified test client. That's expected — click
> **Advanced → Continue**. The requested scope is `gmail.modify` plus your basic
> profile (email/name); DreaMail never sees a password.

### Why bring your own OAuth client?

Shipping a shared client ID would make DreaMail a data broker for every
user's mailbox and would drag the project through Google's restricted-scope
verification (a CASA security assessment for `gmail.modify`). Bring-your-own
client keeps your mail flowing only between your Mac and Google — nobody else,
including the author, is ever in the loop. It costs you five minutes once.

## Build & run

```sh
brew install xcodegen        # once
xcodegen generate
xcodebuild -project DreaMail.xcodeproj -scheme DreaMail -configuration Release build
```

Or, with the included Makefile:

```sh
make run      # build + open the isolated Debug app with your real account
make demo     # build + open the isolated fictional inbox (same as make run DEMO=1)
make build    # generate + build without launching
make test     # run the hostless unit tests
make ui-test  # run the demo-inbox UI smoke test
make hooks    # pre-commit runs unit tests; post-merge removes merged branches and worktrees
make checks   # shellcheck + Python script tests + CI pin checks (no Xcode)
```

You can also open `DreaMail.xcodeproj` in Xcode. Configure the free Personal
Team signing described below before running a real inbox; use `make demo` (or
`make run DEMO=1`) for the no-signing, Keychain-free demo.

### Signing

By default the app is **ad-hoc signed** ("Sign to Run Locally"), so it compiles
and runs the fictional demo on any Mac with no Apple account. The demo never
touches Keychain. Signing settings live in
[`Config/Signing.xcconfig`](Config/Signing.xcconfig).

Do not use an ad-hoc build with a real inbox. Apple ties an ad-hoc app's
identity to that exact build, so macOS asks for Keychain access again after the
code changes. `make install` and `make run` (without `DEMO=1`) therefore require a stable
local signing identity instead of silently installing an app that will
re-prompt. Run `make signing-doctor` if the identity is missing.

**The $99 Apple Developer Program is not required for personal use.** Sign in
with any Apple Account under **Xcode → Settings → Apple Accounts**. Xcode gives
unpaid accounts a free **Personal Team**. Select it, open **Manage
Certificates**, and create an **Apple Development** certificate. Then create
`Config/Local.xcconfig` (git-ignored) using the Team ID shown in the
certificate's name:

```
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM = XXXXXXXXXX
CODE_SIGN_IDENTITY = Apple Development
```

The first stable build may ask once for each item created by an older ad-hoc
build; choose **Always Allow**. Subsequent rebuilds keep the same identity and
do not ask again.

Paid membership is only needed to distribute a Developer ID signed and
notarized build to other Macs. An ad-hoc/source installation never updates
itself in place, even with a release channel configured: with no Team ID of
its own there is no publisher to check an update against, and "any notarized
Developer ID" is something any publisher can provide. Update it with
`make install`. `make release` explicitly rejects
free Personal Team and ad-hoc identities so they cannot accidentally be
published as updates for other users.

### Releases & updates

**In this fork the updater is disabled.** The release channel is a build
setting with no default (`DREAMAIL_UPDATE_CHANNEL` in
[`Config/Signing.xcconfig`](Config/Signing.xcconfig), `OWNER/REPO`), and the
tracked value is empty: the app makes no release checks, never contacts a
releases API, and never replaces itself; Settings → Updates says updates are
disabled. Update a source build with `make install`. The rest of this section
describes the updater as it behaves once a channel you publish and sign is
configured in `Config/Local.xcconfig` **and** the build is signed with a Team
ID; an ad-hoc build stays inert even with a channel.

With a channel configured, the
app checks once a day; when a newer version exists, an **Update app** button
appears at the bottom of the sidebar and an **Install and Relaunch** button in
**Settings → Updates** — clicking either downloads and verifies the release
zip, replaces DreaMail where it's installed, and restarts it. Because the app
is sandboxed, the *first* update asks once for permission to its own install
folder (usually `/Applications`); the grant is remembered, so later updates are
a single click. If that permission is declined or the swap fails, the verified
app is revealed in Finder to drag in by hand.

To update from the terminal instead — or to cross from a build older than
0.4.1, whose updater predates all of this — run:

```sh
scripts/update-dreamail.sh --repo OWNER/REPO
```

The repository is required: there is no default channel. It runs the same
checks the app does (SHA-256 against `SHA256SUMS`, code signature, Team ID
continuity and bundle identifier of the install it's replacing, and the
release version against the bundle's own), installs only a strictly newer
version, then replaces `/Applications/DreaMail.app` and relaunches. Pass a
path as the last argument if DreaMail lives elsewhere; `--allow-downgrade`
reinstalls the same or an older release, for recovery only.

To cut a release: bump `MARKETING_VERSION` in `project.yml`, then

```sh
make release    # runs tests, builds Release, zips, gh release create v<version>
```

See [docs/RELEASING.md](docs/RELEASING.md) for the full step-by-step checklist,
tag/version rules, Developer ID signing + notarization, and troubleshooting.

For a distributable binary, sign with a Developer ID, keep
`ENABLE_HARDENED_RUNTIME` on (it already is), and notarize with `notarytool`.
Each user still needs their own Google OAuth client (see above), so building
from source stays a first-class path.


### Screenshots

The images in this README come straight from the real app (`make run` or
`make install`). Before capturing, pick or set up an inbox you're comfortable
publishing — redact/crop anything sensitive (real names, subjects, addresses)
before saving. Capture with **⌘⇧4 then Space** to grab the window, and save
into [`docs/screenshots/`](docs/screenshots/) using the filenames referenced
above.


## Keyboard shortcuts

Press **`?`** anywhere to see the full cheat sheet, reflecting any custom
bindings. The single-key commands below are **customizable** in **Settings →
Keyboard shortcuts** — click a key, press the new one (conflicts are refused).
The defaults are Gmail's:

| Key | Action | | Key | Action |
|---|---|---|---|---|
| j / k | Next (older) / previous (newer) thread | | r | Reply |
| o | Open thread (Return also opens) | | a | Reply all |
| u | Back to the thread list | | f | Forward newest message (new conversation; use thread ⋮ → Forward all for the whole thread) |
| x | Select / deselect (multi-select) | | l | Label… |
| e | Archive | | c | Compose |
| ] / [ | Archive the open conversation, go to the next / previous | | | |
| # | Trash | | z | Undo last action |
| s | Star / unstar | | ! | Report spam / not spam |
| b or h | Snooze… (picker) | | — | Toggle read / unread (no default key; Gmail uses Shift-I / Shift-U) |

A custom key always keeps its place: if it is a key that a later version makes
the default of another command, that command is left without a key (shown as
"—" in Settings) until you give it one.

Fixed shortcuts (not customizable):

| Key | Action |
|---|---|
| Shift-I / Shift-U | Mark as read / Mark as unread (Gmail) |
| Shift-N | Refresh (sync all accounts) |
| g then i / s / b / t / d / a / l / p | Go to Inbox / Starred / Snoozed / Sent / Drafts / All mail / Labels / Promotions |
| * then a / n / r / u / s / t | Select all / none / read / unread / starred / unstarred threads |
| ↑ / ↓ | Browse threads (without opening the reading pane) |
| Return | Open selected thread · Esc closes the reading pane |
| / | Search |
| ? | Show the keyboard-shortcut cheat sheet |
| Cmd-K | Command palette · in compose body: insert/edit link |
| Cmd-L | Copy Gmail link to the selected thread |
| Ctrl-F | Filter menu |
| Cmd-N | Compose · Cmd-Enter send |
| Cmd-Shift-C / Cmd-Shift-B / Cmd-Shift-F (in compose) | Add Cc / add Bcc / choose the From address |
| / (in compose body) | Snippet picker — type `/name` to filter, Return inserts |
| Cmd-/ (in compose) | Toggle the snippets panel |
| ⌘B / ⌘I / ⌘⇧X / ⌘E | Bold / italic / strikethrough / code (compose body) |
| ⌘⇧M / ⌘⌥1–3 / ⌘⇧9 or ⌘⇧. / ⌘⇧8 | Math / H1–H3 / quote / bullet (compose body) |
| Cmd-Shift-R | Sync all |
| Cmd-+ / Cmd-− / Cmd-0 | Text size |
| Cmd-, | Settings |

Single-key shortcuts never fire while you are typing in a field (search,
compose, Settings).

## AI (optional)

**In this fork the AI features and the MCP server are switched off.** The
switch is a build setting (`DREAMAIL_AI_FEATURES` in
[`Config/Signing.xcconfig`](Config/Signing.xcconfig)) whose tracked value is
empty: no AI control is shown, no model provider, custom endpoint or Ollama
daemon is contacted, no stored provider key is read, and the MCP server never
starts, whatever an earlier build stored. Set `DREAMAIL_AI_FEATURES = YES` in
`Config/Local.xcconfig` to build them in; the rest of this section and the
MCP section describe that build.

Mail text stays on this Mac unless you assign a task to a hosted model.

In compose, **AI draft** opens a short instruction field (for example, “ask
for two more days”). Replies use the conversation, including earlier
decisions, and stream into a separate preview. **Use draft** applies it;
**Undo** restores your text. Rewrite, shorten, and tone changes work on a
selection or the whole authored draft. Generated text never overwrites edits
made while the model is working. Set your preferred tone, sign-off, or booking
link once in **Settings → AI → How I write**; drafts, suggested replies, and
Ask AI reuse it.

Thread summaries include the current state and a **Next** action. Completed
summaries are saved locally; new replies flag them for **Refresh**. In
**Settings → AI**, you can opt into summaries when opening long threads with
Ollama on this Mac. Hosted and LAN models always use the explicit summary
button. Ask AI refreshes changed open and pinned conversations on the next
question, and keeps each question tied to the thread that was selected when
you asked it.

**Local (default).** Install [Ollama](https://ollama.com) and pull a small model:

```sh
ollama pull llama3.2
```

Then in **Settings → AI** point DreaMail at your local Ollama (default
`http://127.0.0.1:11434`). Drafts, summaries, triage, and Ask AI run on
this Mac. DreaMail refuses cleartext non-loopback endpoints. LAN Ollama
(RFC1918 / link-local) is treated as on-network, not as a cloud host.

**Hosted.** Settings → AI can connect Claude, ChatGPT, Grok, Gemini,
OpenRouter, or a custom OpenAI-compatible endpoint. Each task (drafts,
summaries, triage, Ask AI) has its own assignment. A hosted assignment
sends that task's mail text to the provider. Preset hosts are expected;
a typed-in host requires an explicit consent that matches scheme, host, and
port. Silent inbox auto-sort skips when Triage is a cloud model so new-mail
snippets are not uploaded in the background. Ask AI shows a one-time notice
before a hosted chat.

## Where things live

This fork's bundle identifier is `io.github.bateman.DreaMail` (Debug:
`io.github.bateman.DreaMail.debug`), so it has its own sandbox container,
defaults domain and Keychain items:

- Mail cache (SQLCipher-encrypted): `~/Library/Containers/io.github.bateman.DreaMail/Data/Library/Application Support/DreaMail/mail.sqlite`
- OAuth refresh tokens, client secret, and the DB key: macOS Keychain (`io.github.bateman.DreaMail`)

### Coming from a MishMail install of this fork

Until November 2026 this fork was called MishMail, with bundle identifier
`io.github.bateman.MishMail` (Debug: `io.github.bateman.MishMail.debug`).
DreaMail is a new app to macOS: nothing is migrated, so install DreaMail,
paste the Google client ID and secret again, sign in to each account and let
it resync. Local-only data (signatures, saved views, VIPs, blocked senders,
local drafts, scheduled sends) stays in the old container. Once DreaMail
works, quit MishMail and remove what it left behind:

```sh
# The old app, and its mail cache, attachments, logs and preferences
rm -rf /Applications/MishMail.app
rm -rf ~/Library/Containers/io.github.bateman.MishMail ~/Library/Containers/io.github.bateman.MishMail.debug
rm -f ~/Library/Logs/MishMailRelauncher.log
# Old Google refresh tokens, client secret, database key and OpenPGP keys.
# Each command deletes one item; repeat until it reports that none was found.
security delete-generic-password -s io.github.bateman.MishMail
security delete-generic-password -s io.github.bateman.MishMail.debug
security delete-generic-password -s io.github.bateman.MishMail.openpgp
security delete-generic-password -s io.github.bateman.MishMail.debug.openpgp
```

If you installed the daily-summary agent, unload it with
`launchctl bootout gui/$(id -u)/io.github.bateman.mishmail-summarize` and
delete `~/Library/LaunchAgents/io.github.bateman.mishmail-summarize.plist`.
A `Config/Local.xcconfig` that still sets `MISHMAIL_…` switches is ignored:
rename them to `DREAMAIL_…`. A notarization profile stored as
`MishMail-notary` must be stored again as `DreaMail-notary`.

### Coming from an upstream (`dev.ronboger.MishMail`) install

Nothing is migrated: the first launch of this fork starts fresh, so sign in
to Google again and let it resync. The old install's data stays where it was
until you remove it. Quit both apps first, then:

```sh
# Old mail cache, attachments and preferences (Release and Debug)
rm -rf ~/Library/Containers/dev.ronboger.MishMail ~/Library/Containers/dev.ronboger.MishMail.debug
# Old Google refresh tokens, client secret and database key. Each command
# deletes one item; repeat until it reports that none was found.
security delete-generic-password -s dev.ronboger.MishMail
security delete-generic-password -s dev.ronboger.MishMail.debug
```

Then revoke the old app's access in your Google Account (Security → Your
connections to third-party apps & services), unless this fork uses the same
OAuth client and you want to keep the grant.

## Security

- **OAuth 2.0 Authorization Code + PKCE**, loopback redirect bound to
  `127.0.0.1` only (RFC 8252), fixed callback path, 5-minute listener timeout,
  and state-checked responses so a local probe can't abort or hijack sign-in.
  Tokens go straight to the Keychain (device-bound, not synced to iCloud,
  excluded from backups).
- **Encrypted at rest** — the local mail cache is SQLCipher-encrypted with a
  256-bit key held only in the Keychain.
- **HTML email is sandboxed** — rendered with JavaScript disabled, a strict CSP
  (`default-src 'none'`, `base-uri 'none'`, no forms/frames/objects), an
  ephemeral web data store, and a default-deny navigation policy, so crafted
  mail cannot navigate the pane or submit forms. Its only network access is
  fetching HTTPS images (never cleartext http), when remote images are allowed.
  Links open in your default browser.
- **Remote images load by default when a message is opened**: clicking it,
  moving to it in the list while the reading pane is showing, or landing on it
  after archive or delete. The sender's servers then learn when you opened it,
  your IP address (approximate location and network), and details of the mail
  client (macOS WebKit User-Agent, language). Exceptions under every setting:
  mail in Spam needs its own click, and conversations you have not opened
  (including the neighbors DreaMail pre-renders for fast navigation) never load
  remote images. To stop it, choose Settings → Appearance → Load remote images
  → Ask each time (or VIP senders, which loads only for VIPs that pass Gmail's
  authentication checks); Load images then works per message or per
  conversation. Residual risks are listed in [SECURITY.md](SECURITY.md#remote-images).
- **Attachments** written to disk are tagged with the quarantine attribute, so
  Gatekeeper's first-open checks still apply; opening app/script/installer-like
  filenames asks for confirmation first.
- **Updates are verified** — "Update App" downloads the release zip, checks the
  published **SHA-256**, the embedded app's code signature, **Team ID** continuity
  with the running build, and **notarization** for Developer ID releases, then
  reveals the app in Finder. A failed check opens the GitHub release page
  instead of handing you an unverified binary.
- **App Sandbox** enabled with a minimal entitlement set (network client, the
  transient loopback listener for sign-in, and user-selected file access).
  `make release` uses `DreaMail.Distribution.entitlements` (library validation
  on) whenever `Config/Local.xcconfig` sets a `DEVELOPMENT_TEAM` — see
  [docs/RELEASING.md](docs/RELEASING.md).
- **No secret logging**, parameterized SQL throughout, CRLF-folded MIME headers,
  and path-traversal-safe attachment filenames.
- **No bundled Google secrets** — every user (and every Debug vs Release copy)
  pastes their own OAuth client in Settings. Gmail traffic goes to Google.
  Each account's own profile photo is fetched from Google's photo hosts
  (`lh3`–`lh6.googleusercontent.com`, HTTPS only, no token, no redirects),
  at most once a day, and stored with the account in the encrypted cache.
  Accounts without a photo show the letter image Google generates for them.
  Optional AI is local Ollama by default; a hosted model you assign in
  Settings → AI sends that task's mail text to that provider, only after
  host-consent checks. Silent auto-sort never uses a hosted provider.
- Snooze and reminders are local-only (Gmail's API has no snooze); everything
  else — archive, trash, star, read state, send/reply — syncs to Gmail
  immediately.

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## License

[MIT](LICENSE) © 2026 Ron Boger. DreaMail is derived from
[MishMail](https://github.com/ronboger/mishmail) by Ron Boger. Depends on
[GRDB.swift](https://github.com/duckduckgo/GRDB.swift) (SQLCipher build, MIT).
