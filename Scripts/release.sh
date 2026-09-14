#!/usr/bin/env bash
# Builds a release zip for GitHub: runs the tests, builds a universal AgentBar.app (Apple silicon
# and Intel) with an ad-hoc signature, and writes the zip and its SHA-256 to dist/.
#
# AgentBar isn't signed with a Developer ID or notarized, so macOS quarantines a downloaded copy;
# the README says how to open it.
#
# Usage: Scripts/release.sh <version>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: Scripts/release.sh <version like 1.2.3>" >&2
    exit 1
fi

APP="$ROOT/AgentBar.app"
DIST="$ROOT/dist"
ZIP="$DIST/AgentBar-$VERSION.zip"
ARCHS="arm64 x86_64"

step() { printf '\n==> %s\n' "$*"; }

step "Testing"
swift test

step "Building universal release ($ARCHS)"
swift build -c release --arch arm64 --arch x86_64
CONFIGURATION=release ARCHS="$ARCHS" "$ROOT/Scripts/bundle.sh"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/AgentBar")"

step "Stamping version $VERSION"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$PLIST"
# The plist changed, so sign again (ad hoc, as bundle.sh does).
codesign --force --sign - "$APP"

step "Packaging"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"

step "Done"
echo "  $ZIP"
echo "  $ZIP.sha256  ($SHA256)"
