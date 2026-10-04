#!/bin/bash
# Builds "Manga to Kindle.app" with swiftc (no Xcode) and bundles the engine, KCC and kindlegen.
# Python deps live in ~/MangaKindle/venv (see ../setup.sh).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=..
APP="build/Manga to Kindle.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine" "$APP/Contents/Resources/kcc" "$APP/Contents/Resources/bin"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" -o "$APP/Contents/MacOS/MangaToKindle" Sources/*.swift
cp Info.plist "$APP/Contents/"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset; mkdir -p build/AppIcon.iconset
  swift make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp "$ROOT/engine/mangamerge.py" "$ROOT/engine/haru.py" "$ROOT/engine/haru_page.js" "$ROOT/engine/kindle.py" "$ROOT/engine/calibre_send.py" "$APP/Contents/Resources/engine/"
rsync -a --exclude "__pycache__" "$ROOT/engine/kindleunpack" "$APP/Contents/Resources/engine/"
cp "$ROOT/engine/kfx.py" "$APP/Contents/Resources/engine/"
# KFX writer (not redistributable — only bundled into the local app, see setup.sh)
if [ -d "$ROOT/kfx-tool" ]; then mkdir -p "$APP/Contents/Resources/kfx"; cp "$ROOT"/kfx-tool/*.py "$APP/Contents/Resources/kfx/"; fi
cp "$ROOT/kcc-src/kcc-c2e.py" "$ROOT/kcc-src/kcc.py" "$APP/Contents/Resources/kcc/"
rsync -a --exclude '__pycache__' "$ROOT/kcc-src/kindlecomicconverter" "$APP/Contents/Resources/kcc/"
cp "$ROOT/bin/kindlegen" "$APP/Contents/Resources/bin/"
codesign --force --deep -s - "$APP"
echo "built $APP"
