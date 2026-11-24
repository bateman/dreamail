#!/bin/bash
# Install a fixed XcodeGen release for CI and record its version.
#
# Homebrew always installs the newest formula, so two runs of the same
# commit could generate the project with different XcodeGen versions. This
# downloads one release zip, refuses it unless its SHA-256 matches the value
# pinned here, and puts it first on PATH for the rest of the job.
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

curl --fail --silent --show-error --location --retry 3 --proto '=https' \
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
bin="$dest/xcodegen/bin"

installed=$("$bin/xcodegen" --version)
echo "Installed: ${installed} (sha256 ${actual})"
case "$installed" in
  *"$XCODEGEN_VERSION"*) ;;
  *)
    echo "::error::expected XcodeGen ${XCODEGEN_VERSION}, the binary reports '${installed}'"
    exit 1
    ;;
esac

echo "$bin" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "XcodeGen ${XCODEGEN_VERSION} (sha256 \`${actual}\`)" >> "$GITHUB_STEP_SUMMARY"
fi
