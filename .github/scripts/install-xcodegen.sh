#!/bin/bash
# Install a fixed XcodeGen release for CI and record its version.
#
# Homebrew always installs the newest formula, so two runs of the same
# commit could generate the project with different XcodeGen versions. This
# downloads one release zip, refuses it unless its SHA-256 matches the value
# pinned here, and installs it into /usr/local the way the zip's own
# install.sh does. /usr/local/bin is on the PATH the Makefile pins, so
# `make` finds this binary whatever make version runs the recipes.
#
# To upgrade: pick a release at https://github.com/yonaskolb/XcodeGen/releases,
# download its xcodegen.zip, and update both values below from
#   shasum -a 256 xcodegen.zip
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

url="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
dest="${RUNNER_TEMP:?RUNNER_TEMP is not set}/xcodegen-${XCODEGEN_VERSION}"
zip="${dest}.zip"

curl --fail --silent --show-error --location --retry 3 \
  --proto '=https' --proto-redir '=https' \
  --output "$zip" "$url"

actual=$(shasum -a 256 "$zip" | awk '{print $1}')
if [ "$actual" != "$XCODEGEN_SHA256" ]; then
  echo "::error::xcodegen.zip ${XCODEGEN_VERSION} has SHA-256 ${actual}, expected ${XCODEGEN_SHA256}"
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
# The zip holds xcodegen/bin/xcodegen and xcodegen/share/xcodegen; the binary
# finds its setting presets in ../share relative to itself.
unzip -q "$zip" -d "$dest"
prefix=/usr/local
sudo mkdir -p "$prefix/bin" "$prefix/share"
sudo rm -rf "$prefix/share/xcodegen"
sudo cp -R "$dest/xcodegen/share/xcodegen" "$prefix/share/xcodegen"
sudo install -m 0755 "$dest/xcodegen/bin/xcodegen" "$prefix/bin/xcodegen"

# Resolve it the way the Makefile will: with the PATH it exports.
make_path=$(sed -n 's/^export PATH := //p' Makefile)
: "${make_path:?no 'export PATH :=' line in Makefile}"
resolved=$(export PATH="$make_path"; hash -r; command -v xcodegen || true)
if [ "$resolved" != "$prefix/bin/xcodegen" ]; then
  echo "::error::with the Makefile PATH, xcodegen resolves to '${resolved}', not $prefix/bin/xcodegen"
  exit 1
fi

installed=$("$resolved" --version)
echo "Installed: ${installed} at ${resolved} (sha256 ${actual})"
case "$installed" in
  *"$XCODEGEN_VERSION"*) ;;
  *)
    echo "::error::expected XcodeGen ${XCODEGEN_VERSION}, the binary reports '${installed}'"
    exit 1
    ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "XcodeGen ${XCODEGEN_VERSION} (sha256 \`${actual}\`)" >> "$GITHUB_STEP_SUMMARY"
fi
