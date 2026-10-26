#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./tools/build.sh
bundle='build/Project Frontier.app'
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp build/frontier "$bundle/Contents/MacOS/frontier"
mkdir -p "$bundle/Contents/Resources/Licenses"
cp assets/Roboto-LICENSE.txt assets/licenses/*.txt "$bundle/Contents/Resources/Licenses/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Project Frontier</string>
  <key>CFBundleDisplayName</key><string>Project Frontier</string>
  <key>CFBundleIdentifier</key><string>io.github.lenstr.project-frontier</string>
  <key>CFBundleExecutable</key><string>frontier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$bundle"
printf '%s\n' "$bundle"
