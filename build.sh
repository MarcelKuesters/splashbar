#!/bin/bash
set -e
# The source lives next to this script, regardless of where the checkout is
# (e.g. ~/github/splashbar on this machine, any clone on a CI runner).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP=/Applications/SplashBar.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/SplashBar" "$SRC/main.swift" -framework Cocoa
# Localized resources: Resources/<code>.lproj/Localizable.strings
rm -rf "$APP/Contents/Resources/"*.lproj
cp -R "$SRC/Resources/"*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>local.splashbar</string>
 <key>CFBundleName</key><string>SplashBar</string>
 <key>CFBundleExecutable</key><string>SplashBar</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>1.0</string>
 <key>CFBundleDevelopmentRegion</key><string>de</string>
 <key>CFBundleLocalizations</key><array>
  <string>de</string>
  <string>en</string>
  <string>fr</string>
  <string>es</string>
  <string>ja</string>
  <string>zh</string>
  <string>ru</string>
 </array>
 <key>LSMinimumSystemVersion</key><string>14.0</string>
 <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
cat > $HOME/Library/LaunchAgents/local.splashbar.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>local.splashbar</string>
 <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/SplashBar</string></array>
 <key>RunAtLoad</key><true/>
 <key>KeepAlive</key><false/>
 <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
plutil -lint $HOME/Library/LaunchAgents/local.splashbar.plist
launchctl bootout gui/$(id -u)/local.splashbar 2>/dev/null || true
launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/local.splashbar.plist
echo BUILD_OK
