#!/bin/bash
# Install a newer DreaMail release over an existing one, from the terminal.
#
#   scripts/update-dreamail.sh --repo OWNER/REPO                  # /Applications/DreaMail.app
#   scripts/update-dreamail.sh --repo OWNER/REPO ~/Apps/DreaMail.app
#   scripts/update-dreamail.sh --repo OWNER/REPO --allow-downgrade  # recovery only
#
# There is no default release channel. This fork publishes no binaries, and
# pointing an install at a repository you did not choose would let whoever
# controls it replace your app, so the repository must always be named.
#
# Only a strictly newer version is installed. The same or an older release is
# refused, because every old release stays public and correctly signed: a
# stale or malicious "latest" would otherwise roll the install back to a
# vulnerable build. --allow-downgrade lifts that one check, for recovering an
# install that a broken update left unusable.
#
# The checks mirror the in-app updater: SHA-256 against the published
# SHA256SUMS, a full code-signature check, Team ID continuity and the same
# bundle identifier as the app being replaced, and the release version against
# the bundle's own — a stranger's Developer ID can't take over your install
# even if the release repository is compromised.

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  printf 'usage: %s --repo OWNER/REPO [--allow-downgrade] [/path/to/DreaMail.app]\n' "$0" >&2
}

# OWNER/REPO as plain path segments, nothing else: no URL, no extra path.
# The same rule as UpdateChannel.swift: OWNER is [A-Za-z0-9-]+, REPO is
# [A-Za-z0-9._-]+ and not "." or "..".
valid_repo() {
  [[ "$1" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] \
    && [[ "${1#*/}" != "." && "${1#*/}" != ".." ]]
}

# Exit 0 when $1 is strictly newer than $2, comparing dotted numbers
# (0.10.0 > 0.9.0; 0.7 == 0.7.0). Both must be digits and dots only: a
# suffixed tag ("0.8.0-beta.1") or an unreadable installed version ("?") is
# never "newer", so the caller refuses rather than guesses.
version_is_newer() {
  [ "$(version_order "$1" "$2")" = newer ]
}

# Exit 0 when $1 and $2 are the same dotted-number version (0.7 == 0.7.0).
version_is_same() {
  [ "$(version_order "$1" "$2")" = same ]
}

# Prints "newer", "same" or "older" for $1 against $2, or nothing when either
# is not digits and dots only.
version_order() {
  local candidate="$1" current="$2"
  [[ "$candidate" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  [[ "$current" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 0
  local -a a b
  IFS=. read -r -a a <<<"$candidate"
  IFS=. read -r -a b <<<"$current"
  local n=$(( ${#a[@]} > ${#b[@]} ? ${#a[@]} : ${#b[@]} ))
  local i x y
  for (( i = 0; i < n; i++ )); do
    # 10# forces base ten: a component like "08" is not octal.
    x=$(( 10#${a[i]:-0} ))
    y=$(( 10#${b[i]:-0} ))
    if (( x > y )); then echo newer; return 0; fi
    if (( x < y )); then echo older; return 0; fi
  done
  echo same
}

# HTTPS only, including every redirect.
fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' "$@"
}

main() {
set -euo pipefail

REPO=""
ALLOW_DOWNGRADE=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      [ $# -ge 2 ] || { usage; die "--repo needs OWNER/REPO"; }
      REPO="$2"; shift 2 ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "unknown option $1" ;;
    *)
      [ -z "$TARGET" ] || { usage; die "more than one app path given"; }
      TARGET="$1"; shift ;;
  esac
done
TARGET="${TARGET:-/Applications/DreaMail.app}"

# Before anything else, and above all before any network request.
[ -n "$REPO" ] || { usage; die "no release repository given: pass --repo OWNER/REPO (there is no default channel)"; }
valid_repo "$REPO" || die "--repo must be OWNER/REPO, got '$REPO'"

[ -d "$TARGET" ] || die "no app at $TARGET (pass its path as the last argument)"

# Team ID of the install we're replacing. Empty means ad-hoc: those builds
# come from source, and `make install` is the way to update them.
team_of() {
  codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}
INSTALLED_TEAM="$(team_of "$TARGET")"
if [ -z "$INSTALLED_TEAM" ] || [ "$INSTALLED_TEAM" = "not set" ]; then
  die "$TARGET is ad-hoc signed (built from source) — update it with 'make install'"
fi
# Both go into the code-signing requirement below, so they must be the plain
# tokens they claim to be.
[[ "$INSTALLED_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
  || die "unexpected Team ID '$INSTALLED_TEAM' on $TARGET"

bundle_id_of() {
  plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null
}
INSTALLED_ID="$(bundle_id_of "$TARGET" || true)"
[[ "$INSTALLED_ID" =~ ^[A-Za-z0-9.-]+$ ]] \
  || die "couldn't read a bundle identifier from $TARGET"

command -v curl >/dev/null || die "curl not found"

printf 'Looking up the latest release…\n'
API="https://api.github.com/repos/$REPO/releases/latest"
RELEASE_JSON="$(fetch -H 'Accept: application/vnd.github+json' "$API")" \
  || die "couldn't reach the GitHub releases API"
# Ask python for the fields rather than grepping the JSON: asset names carry
# the version, so a regex over the whole payload picks up the wrong URLs.
# Assigned in its own step because a failure inside a here-string's command
# substitution wouldn't stop the script.
FIELDS="$(printf '%s' "$RELEASE_JSON" | python3 -c '
import json, sys
rel = json.load(sys.stdin)
assets = {a["name"]: a["browser_download_url"] for a in rel.get("assets", [])}
zip_url = next((u for n, u in assets.items() if n.endswith(".zip")), "")
sums = assets.get("SHA256SUMS", "")
if not zip_url or not sums:
    sys.exit("release is missing a .zip or SHA256SUMS asset")
print(rel["tag_name"], zip_url, sums)
')" || die "couldn'\''t read the latest release"
read -r TAG ZIP_URL SUMS_URL <<<"$FIELDS"

# Assets come from this repository's own release downloads, nowhere else.
ASSET_PREFIX="https://github.com/$REPO/releases/download/"
for url in "$ZIP_URL" "$SUMS_URL"; do
  [[ "$url" == "$ASSET_PREFIX"* ]] \
    || die "release asset $url is not under $ASSET_PREFIX"
done
ZIP_NAME="${ZIP_URL##*/}"
[[ "$ZIP_NAME" =~ ^[A-Za-z0-9._-]+\.zip$ ]] || die "unexpected asset name '$ZIP_NAME'"

version_of() {
  plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null
}
VERSION="${TAG#v}"
CURRENT="$(version_of "$TARGET" || echo '?')"
# Decided on the tag first so nothing is downloaded for a release that would
# be refused; re-checked below against the signed bundle's own version.
if ! version_is_newer "$VERSION" "$CURRENT"; then
  if [ "$ALLOW_DOWNGRADE" -eq 1 ]; then
    printf 'warning: %s is not newer than the installed %s; continuing because of --allow-downgrade\n' \
      "$VERSION" "$CURRENT" >&2
  elif version_is_same "$VERSION" "$CURRENT"; then
    printf 'Already on %s.\n' "$CURRENT"
    exit 0
  else
    die "refusing to install $VERSION over $CURRENT: not a newer version (pass --allow-downgrade to recover an install)"
  fi
fi
printf 'Updating DreaMail %s → %s from %s\n' "$CURRENT" "$VERSION" "$REPO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# Fixed local names: nothing the release chose reaches ditto as a path.
fetch -o release.zip "$ZIP_URL"
fetch -o SHA256SUMS "$SUMS_URL"

printf 'Verifying checksum…\n'
# SHA256SUMS may list assets we didn't download; take the line for ours.
EXPECTED_SUM="$(awk -v name="$ZIP_NAME" \
  '{ file = $2; sub(/^\*/, "", file); if (file == name) { print tolower($1); exit } }' SHA256SUMS)"
[[ "$EXPECTED_SUM" =~ ^[0-9a-f]{64}$ ]] || die "SHA256SUMS does not list $ZIP_NAME"
ACTUAL_SUM="$(shasum -a 256 release.zip | awk '{ print $1 }')"
[ "$ACTUAL_SUM" = "$EXPECTED_SUM" ] || die "SHA-256 did not match the published checksum"

ditto -x -k release.zip extract
NEW_APP="$(find extract -maxdepth 2 -name '*.app' -print -quit)"
[ -n "$NEW_APP" ] || die "release archive contained no .app"

printf 'Verifying signature…\n'
# Anchored like the in-app updater: chains to Apple, carries the installed
# app's Team ID in the leaf certificate, and is the same app. Comparing the
# TeamIdentifier text below alone would trust whatever the signature claims.
REQUIREMENT="anchor apple generic and identifier \"$INSTALLED_ID\" and certificate leaf[subject.OU] = \"$INSTALLED_TEAM\""
codesign --verify --deep --strict -R="$REQUIREMENT" "$NEW_APP" 2>/dev/null \
  || die "the downloaded app is not validly signed by team $INSTALLED_TEAM as $INSTALLED_ID"

NEW_TEAM="$(team_of "$NEW_APP")"
[ "$NEW_TEAM" = "$INSTALLED_TEAM" ] \
  || die "Team ID mismatch (installed $INSTALLED_TEAM, download ${NEW_TEAM:-ad-hoc})"

NEW_VERSION="$(version_of "$NEW_APP")"
# The tag is attacker-controlled if the GitHub account is; the bundle version
# inside the signature is not. Without this, an old signed build could be
# republished under a higher tag to roll the install backwards.
[ "$NEW_VERSION" = "$VERSION" ] \
  || die "release $VERSION contains DreaMail $NEW_VERSION"
# The authenticated comparison: this version is sealed by the signature.
if [ "$ALLOW_DOWNGRADE" -ne 1 ] && ! version_is_newer "$NEW_VERSION" "$CURRENT"; then
  die "refusing to install $NEW_VERSION over $CURRENT: not a newer version"
fi

NEW_ID="$(bundle_id_of "$NEW_APP" || true)"
[ "$NEW_ID" = "$INSTALLED_ID" ] \
  || die "bundle identifier mismatch (installed ${INSTALLED_ID:-unknown}, download ${NEW_ID:-unknown})"

# Every item, not just the bundle root: ditto stamps the attribute onto
# everything it extracts, and the embedded relauncher is an app bundle in its
# own right — leaving it tagged makes macOS refuse to launch it. The app has
# already been verified against the running install's own identity, which is a
# stronger claim than Gatekeeper can make about an un-notarized build.
# (`xattr` here has no -r, hence find.)
find "$NEW_APP" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true

if pgrep -qx DreaMail; then
  printf 'Quitting DreaMail…\n'
  osascript -e 'quit app "DreaMail"' 2>/dev/null || true
  for _ in $(seq 30); do pgrep -qx DreaMail || break; sleep 0.2; done
  pgrep -qx DreaMail && die "DreaMail is still running — quit it and try again"
fi

printf 'Installing…\n'
BACKUP="$WORK/previous-DreaMail.app"
mv "$TARGET" "$BACKUP"
if ! ditto "$NEW_APP" "$TARGET"; then
  mv "$BACKUP" "$TARGET"
  die "install failed; the previous version has been put back"
fi

printf 'Installed DreaMail %s. Launching…\n' "$VERSION"
open "$TARGET"
}

# Run as a file: main. Sourced (the unit tests do): only the helpers above.
# Piped into bash there is no source file at all, and the guard would
# silently do nothing and exit 0 — refuse that loudly instead.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  die "run this as a file (scripts/update-dreamail.sh --repo OWNER/REPO), not piped into a shell"
elif [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
