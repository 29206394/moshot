#!/usr/bin/env bash
# Build SnapPin.app with the system Swift toolchain (no Xcode project needed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/SnapPin.app"
BIN="$APP/Contents/MacOS/SnapPin"

echo "==> cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -framework Cocoa \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework CoreImage \
  -o "$BIN" \
  "$ROOT"/Sources/*.swift

echo "==> packaging"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "    (codesign skipped)"

echo "==> done: $APP"
