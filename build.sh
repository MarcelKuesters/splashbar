#!/bin/bash
set -e
# The source lives next to this script, regardless of where the checkout is
# (e.g. ~/github/splashbar on this machine, any clone on a CI runner).
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CI sets SPLASHBAR_APP to a writable location (the runner's workspace);
# locally the default /Applications is kept.
APP="${SPLASHBAR_APP:-/Applications/SplashBar.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos26.4 -o "$APP/Contents/MacOS/SplashBar" "$SRC/main.swift" -framework Cocoa
# Localized resources: Resources/<code>.lproj/Localizable.strings
rm -rf "$APP/Contents/Resources/"*.lproj
cp -R "$SRC/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>local.splashbar</string>
 <key>CFBundleName</key><string>SplashBar</string>
 <key>CFBundleExecutable</key><string>SplashBar</string>
 <key>CFBundleIconFile</key><string>AppIcon</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>1.0.0</string>
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
 <key>LSMinimumSystemVersion</key><string>26.4</string>
 <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
# Respect the app's "Launch at login" toggle: when the user has turned it off,
# do not (re)install or restart the agent — the app reconciles the file with
# the stored preference on its next start, and the running instance (which
# may have been started manually) is left untouched.
install="${SPLASHBAR_INSTALL:-1}"
launchAtLogin="$(defaults read local.splashbar launchAtLogin 2>/dev/null || true)"
if [ "$launchAtLogin" = "0" ]; then
  echo "Launch-at-login is disabled in the app settings; skipping the local.splashbar LaunchAgent."
elif [ "$install" != "1" ]; then
  echo "SPLASHBAR_INSTALL=0 — skipping LaunchAgent install (CI)."
else
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
fi
# Keep the splash agent's RunAtLoad in sync with the same preference. The app
# is the controller of the splash executable, so the executable must not be
# launched separately by launchd at login when the app itself does not start.
# (The app self-heals the same key on every refresh; this covers the gap
# between the build and the app's next start, and files written by older
# builds.) Only the key is patched — the file holds the serve configuration,
# so it is never removed here.
agentPlist="$(defaults read local.splashbar agentPlistPath 2>/dev/null || true)"
if [ -z "$agentPlist" ]; then
  agentLabel="$(defaults read local.splashbar launchdLabel 2>/dev/null || true)"
  [ -z "$agentLabel" ] && agentLabel="local.llm.splash"
  agentPlist="$HOME/Library/LaunchAgents/$agentLabel.plist"
fi
agentPlist="${agentPlist/#\~/$HOME}"
if [ -f "$agentPlist" ]; then
  if [ "$launchAtLogin" = "0" ]; then runAtLoad=false; else runAtLoad=true; fi
  if /usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$agentPlist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :RunAtLoad $runAtLoad" "$agentPlist"
  else
    /usr/libexec/PlistBuddy -c "Add :RunAtLoad bool $runAtLoad" "$agentPlist"
  fi
  echo "Splash agent $agentPlist: RunAtLoad=$runAtLoad"
fi
echo BUILD_OK
