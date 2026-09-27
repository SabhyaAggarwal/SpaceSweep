#!/bin/bash
# Builds SpaceSweep.app into ./build and (optionally) installs it to /Applications.
#
#   ./build.sh            → build/SpaceSweep.app
#   ./build.sh --install  → also copies to /Applications and opens it
#   ./build.sh --run      → build, then launch from ./build
#
# Requirements: macOS 14+, Xcode 15+ or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP=SpaceSweep
OUT=build
BUNDLE="$OUT/$APP.app"

if ! command -v swift >/dev/null; then
  echo "swift not found. Install Xcode or run: xcode-select --install" >&2
  exit 1
fi

echo "==> Building (release)..."
swift build -c release --product "$APP" 2>&1 | grep -vE '^\[|Compiling|Emitting|Write' || true
BIN="$(swift build -c release --show-bin-path)/$APP"
[ -x "$BIN" ] || { echo "Build failed - see errors above." >&2; exit 1; }

echo "==> Assembling ${BUNDLE}..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ -f Resources/AppIcon.png ]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Ad-hoc signature so macOS remembers the app's privacy permissions (Full Disk Access etc.)
# across rebuilds. Not sandboxed: the app needs to read ~/Library.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "==> Built ${BUNDLE}"

case "${1:-}" in
  --install)
    echo "==> Installing to /Applications..."
    rm -rf "/Applications/$APP.app"
    cp -R "$BUNDLE" "/Applications/$APP.app"
    open "/Applications/$APP.app"
    ;;
  --run)
    open "$BUNDLE"
    ;;
esac
