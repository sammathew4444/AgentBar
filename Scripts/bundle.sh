#!/usr/bin/env bash
# Assembles AgentBar.app from the binary produced by `swift build`.
# Usage: swift build && ./Scripts/bundle.sh
#        CONFIGURATION=release ./Scripts/bundle.sh                        (after swift build -c release)
#        CONFIGURATION=release ARCHS="arm64 x86_64" ./Scripts/bundle.sh  (after a universal build)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
ARCH_FLAGS=()
for arch in ${ARCHS:-}; do
    ARCH_FLAGS+=(--arch "$arch")
done
# The ${…+…} form keeps bash 3.2 (macOS /bin/bash) happy with an empty array under `set -u`.
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BINARY="$BIN_DIR/AgentBar"
APP="$ROOT/AgentBar.app"

if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY not found. Run 'swift build -c $CONFIGURATION ${ARCH_FLAGS[*]:-}' first." >&2
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

# Omarchy's themes (themes/<id>/colors.toml), offered by the panel's theme button.
for f in "$ROOT"/Resources/Themes/*/colors.toml; do
    theme="$(basename "$(dirname "$f")")"
    mkdir -p "$APP/Contents/Resources/Themes/$theme"
    cp "$f" "$APP/Contents/Resources/Themes/$theme/colors.toml"
done

# Agent marks from Omarchy's agents plugin (assets/<id>.svg), shown in the panel hero.
mkdir -p "$APP/Contents/Resources/Agents"
for f in "$ROOT"/Resources/Agents/*.svg; do
    cp "$f" "$APP/Contents/Resources/Agents/"
done
shopt -u nullglob

# Ad-hoc signature so the bundle launches. AgentBar isn't Developer ID signed or notarized.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($CONFIGURATION${ARCHS:+, $ARCHS})"
