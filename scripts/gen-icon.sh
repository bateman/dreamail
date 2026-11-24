#!/bin/sh
# Regenerate the AppIcon PNGs from Design/AppIcon.svg when the SVG changed.
#
# The app icon ships as PNGs in the asset catalog; the SVG is only the source.
# Change is detected by content hash (Design/.AppIcon.sha256, committed), not
# mtime: a fresh clone gives every file the same timestamp, which would make
# an mtime rule re-export (and dirty git) for everyone.
#
# After a re-export on macOS it also flushes the icon cache (sudo, so only in
# an interactive terminal) and restarts Dock/Finder, otherwise the Dock keeps
# showing the old icon. Skip with ICON_CACHE=0.
#
# Needs rsvg-convert (`brew install librsvg`). If it is missing the script
# warns and exits 0, so contributors who never touch the icon can still build.
set -eu
cd "$(dirname "$0")/.."

SVG=Design/AppIcon.svg
STAMP=Design/.AppIcon.sha256
SET=Sources/MishMail/Assets.xcassets/AppIcon.appiconset
SIZES="16 32 64 128 256 512 1024"

want=$(shasum -a 256 "$SVG" | cut -d' ' -f1)
have=$(cat "$STAMP" 2>/dev/null || true)
[ "$want" = "$have" ] && exit 0

if ! command -v rsvg-convert >/dev/null 2>&1; then
	echo "warning: $SVG changed but rsvg-convert is missing; app icon NOT updated."
	echo "         brew install librsvg && make icon"
	exit 0
fi

echo "$SVG changed: regenerating app icon PNGs"
for s in $SIZES; do
	rsvg-convert -w "$s" -h "$s" "$SVG" -o "$SET/icon_$s.png"
done
echo "$want" > "$STAMP"

# Only reached after a real re-export. Needs a terminal for the sudo prompt, so
# CI and non-interactive runs skip it.
if [ "$(uname)" = Darwin ] && [ "${ICON_CACHE:-1}" = 1 ] && [ -t 0 ]; then
	echo "flushing macOS icon cache (sudo password may be requested)"
	sudo rm -rf /Library/Caches/com.apple.iconservices.store || true
	killall Dock Finder 2>/dev/null || true
fi
