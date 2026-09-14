#!/usr/bin/env bash
# Assembles AgentBar.app from the binary produced by `swift build`.
# Usage: swift build && ./Scripts/bundle.sh
#        CONFIGURATION=release ./Scripts/bundle.sh   (after swift build -c release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/AgentBar"
APP="$ROOT/AgentBar.app"

if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY not found. Run 'swift build -c $CONFIGURATION' first." >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

cp "$BINARY" "$APP/Contents/MacOS/AgentBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Nerd Font and its OFL licence. Loaded via ATSApplicationFontsPath in Info.plist.
shopt -s nullglob
for f in "$ROOT"/Resources/Fonts/*.{ttf,otf} "$ROOT"/Resources/Fonts/OFL*; do
    cp "$f" "$APP/Contents/Resources/Fonts/"
done
shopt -u nullglob

# Ad-hoc signature so the bundle launches locally. Developer ID signing lives in release.sh.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($CONFIGURATION)"
