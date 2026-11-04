#!/bin/zsh
# Build the app bundle. The default output folder ends in .noindex so Spotlight
# and Launchpad never list build copies as extra "LLM Usage" apps.
set -eu
SOURCE=${0:A:h}
DEST=${1:-$HOME/Library/Caches/LLMUsage.noindex/LLM Usage.app}
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$SOURCE/Info.plist" "$DEST/Contents/Info.plist"
cp "$SOURCE/AppIcon.icns" "$SOURCE/widget.html" "$SOURCE/accounts.json" "$DEST/Contents/Resources/"
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/llm-swift-cache" "$SOURCE/App.swift" "$SOURCE/MenuBar.swift" "$SOURCE/Accounts.swift" -o "$DEST/Contents/MacOS/LLMUsage" -framework AppKit -framework WebKit
codesign --force --deep --sign - "$DEST"
codesign --verify --deep --strict "$DEST"
