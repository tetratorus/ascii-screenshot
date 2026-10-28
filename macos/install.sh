#!/bin/bash
# Install ascii-screen as a per-user background service (LaunchAgent).
#   ./install.sh [ascii-screen flags...]   build, install, start (default flags: --out ~/.ascii-screen/screen.txt)
#   ./install.sh --uninstall               stop and remove
set -euo pipefail
LABEL=com.tetratorus.ascii-screen
APP="$HOME/Applications/ASCII Screen.app"
BIN="$APP/Contents/MacOS/ascii-screen"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/.ascii-screen"
LOG="$HOME/Library/Logs/ascii-screen.log"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -rf "$APP" "$PLIST"
  echo "Removed. Output in $DATA and log $LOG were kept."
  exit 0
fi

cd "$(dirname "$0")"
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$DATA" "$(dirname "$PLIST")" "$(dirname "$LOG")"
cp .build/release/ascii-screen "$BIN"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>ASCII Screen</string>
  <key>CFBundleExecutable</key><string>ascii-screen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
# A stable signing identity keeps the Screen Recording grant across rebuilds.
codesign --force --sign - --identifier "$LABEL" "$APP"

ARGS=("$@"); [[ ${#ARGS[@]} -eq 0 ]] && ARGS=(--out "$DATA/screen.txt")
{
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string>
PL
  for a in "${ARGS[@]}"; do printf '    <string>%s</string>\n' "$a"; done
  cat <<PL
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL
} > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Running as $LABEL. Output: ${ARGS[*]}  Log: $LOG"
echo "First run: allow 'ASCII Screen' in System Settings > Privacy & Security > Screen Recording; it restarts itself within 30s."
