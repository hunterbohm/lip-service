#!/bin/bash
# Builds dist/RivalBench.app, signed with the local certificate so its Accessibility grant survives rebuilds.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
app="$root/dist/RivalBench.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 6 "$here/RivalBench.swift" -o "$app/Contents/MacOS/RivalBench"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hunterbohm.rivalbench</string>
<key>CFBundleExecutable</key><string>RivalBench</string>
<key>CFBundleName</key><string>RivalBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
"$root/scripts/sign.sh" "$app" com.hunterbohm.rivalbench
echo "$app"
