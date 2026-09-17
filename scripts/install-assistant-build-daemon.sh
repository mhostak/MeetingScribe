#!/bin/bash
# Install, reinstall or remove the assistant build daemon.
#
# The daemon runs as a LaunchAgent inside the logged-in GUI session, so the login
# Keychain is unlocked and signing needs no password file. Because the repository
# lives under the TCC-protected ~/Documents, the agent's program is a dedicated
# app bundle in ~/Applications that you grant Full Disk Access once — rather than
# granting it to /usr/bin/python3, which would cover every python process.
#
#   scripts/install-assistant-build-daemon.sh            # install and start
#   scripts/install-assistant-build-daemon.sh --status
#   scripts/install-assistant-build-daemon.sh --uninstall

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.meetingscribe.assistant-build"
BUNDLE_ID="com.meetingscribe.assistant-build-daemon"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/MeetingScribeBuildDaemon.app"
EXECUTABLE="$APP/Contents/MacOS/MeetingScribeBuildDaemon"
STAMP="$APP/Contents/Resources/build-stamp"
QUEUE="$REPO/.claude/build-queue"
DAEMON="$REPO/scripts/assistant_build_daemon.py"
LAUNCHER="$REPO/scripts/assistant_build_launcher.c"
CLIENT="$REPO/scripts/assistant_build_client.py"
TARGET="gui/$(id -u)/$LABEL"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

open_fda_settings() {
  cat <<'FDA'

  Grant Full Disk Access to the daemon:

    1. System Settings -> Privacy & Security -> Full Disk Access
    2. Click +
    3. Press Cmd+Shift+G and paste:
FDA
  echo "         $APP"
  cat <<'FDA'
    4. Select MeetingScribeBuildDaemon and make sure its switch is on
    5. Re-run this installer, or:
         launchctl kickstart -k TARGET_PLACEHOLDER

  Without that grant the agent cannot read the repository under ~/Documents.
FDA
}

case "${1:---install}" in
  --status)
    echo "label:      $LABEL"
    echo "bundle:     $APP $([ -x "$EXECUTABLE" ] && echo '(built)' || echo '(MISSING)')"
    echo "plist:      $PLIST $([ -f "$PLIST" ] && echo '(installed)' || echo '(not installed)')"
    launchctl print "$TARGET" 2>/dev/null | sed -n '1,10p' || echo "not loaded"
    echo
    python3 "$CLIENT" status || true
    exit 0
    ;;
  --uninstall)
    launchctl bootout "$TARGET" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$APP"
    echo "removed $LABEL and $APP"
    echo "Remove the stale Full Disk Access entry in System Settings as well."
    echo "The queue in $QUEUE was left untouched."
    exit 0
    ;;
  --install) ;;
  *) usage; exit 64 ;;
esac

for required in "$DAEMON" "$LAUNCHER" "$CLIENT"; do
  [ -f "$required" ] || { echo "error: $required is missing" >&2; exit 1; }
done
[ -d /Applications/Xcode.app ] || { echo "error: /Applications/Xcode.app not found" >&2; exit 1; }
command -v clang >/dev/null || { echo "error: clang not found; run xcode-select --install" >&2; exit 1; }

chmod +x "$DAEMON" "$CLIENT" "${BASH_SOURCE[0]}"
mkdir -p "$QUEUE"/{requests,results,logs,archive} "$HOME/Library/LaunchAgents" "$HOME/Applications"
printf '*\n!.gitignore\n' > "$QUEUE/.gitignore"

# Rebuilding changes the code signature, which invalidates the Full Disk Access
# grant. So the binary is only rebuilt when its inputs actually changed.
WANT_STAMP="$(printf '%s\0%s' "$DAEMON" "$(shasum -a 256 "$LAUNCHER" | cut -d' ' -f1)" | shasum -a 256 | cut -d' ' -f1)"
HAVE_STAMP="$([ -f "$STAMP" ] && cat "$STAMP" || echo none)"
REBUILT=no

if [ ! -x "$EXECUTABLE" ] || [ "$WANT_STAMP" != "$HAVE_STAMP" ]; then
  echo "building $APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>MeetingScribeBuildDaemon</string>
  <key>CFBundleDisplayName</key>
  <string>MeetingScribe Build Daemon</string>
  <key>CFBundleExecutable</key>
  <string>MeetingScribeBuildDaemon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$APP/Contents/Info.plist" >/dev/null

  clang -O2 -Wall -Wextra -Werror \
    -DDAEMON_SCRIPT="\"$DAEMON\"" \
    -o "$EXECUTABLE" "$LAUNCHER"

  # A Developer ID signature keeps the same TCC identity across rebuilds; an
  # ad-hoc one changes with every build and costs you the grant again.
  IDENTITY="$(grep -Eho '[0-9A-Fa-f]{40}' "$REPO/Config/Signing.local.xcconfig" 2>/dev/null | head -1 || true)"
  if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qi "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
    echo "signed with the identity configured in Config/Signing.local.xcconfig"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "warning: signed ad-hoc; every rebuild will invalidate the Full Disk Access grant" >&2
  fi

  printf '%s' "$WANT_STAMP" > "$STAMP"
  REBUILT=yes
else
  echo "reusing the existing bundle (unchanged inputs, so the grant survives)"
fi

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXECUTABLE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DEVELOPER_DIR</key>
    <string>/Applications/Xcode.app/Contents/Developer</string>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Standard</string>
  <key>StandardOutPath</key>
  <string>$QUEUE/launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$QUEUE/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null

: > "$QUEUE/launchd.err.log"
launchctl bootout "$TARGET" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "$TARGET" 2>/dev/null || true

# The only honest check is whether the daemon actually registered in the queue.
echo -n "waiting for the daemon to register"
REGISTERED=no
for _ in $(seq 1 15); do
  if [ -f "$QUEUE/daemon.lock" ]; then REGISTERED=yes; break; fi
  echo -n "."
  sleep 1
done
echo

if [ "$REGISTERED" = yes ]; then
  echo "daemon is running (pid $(cat "$QUEUE/daemon.lock"))"
  echo
  echo "Verify end to end with:"
  echo "  python3 $CLIENT ping"
else
  echo "daemon did NOT register." >&2
  if grep -qi "operation not permitted" "$QUEUE/launchd.err.log" 2>/dev/null; then
    echo "Cause: Full Disk Access is missing for the daemon bundle." >&2
    open_fda_settings | sed "s|TARGET_PLACEHOLDER|$TARGET|"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
  else
    echo "Check $QUEUE/launchd.err.log" >&2
    tail -5 "$QUEUE/launchd.err.log" 2>/dev/null || true
  fi
  exit 1
fi

[ "$REBUILT" = yes ] && cat <<NOTE

Note: the bundle was (re)built, so its code signature changed. If it was already
in Full Disk Access, remove the old entry and add it again.
NOTE

echo
echo "Stop it any time with:"
echo "  launchctl bootout $TARGET"
