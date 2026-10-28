#!/bin/bash
# Install ascii-screen as a per-user background service (LaunchAgent).
#   ./install.sh [ascii-screen flags...]   build, install, start (default flags: --out ~/.ascii-screen/screen.txt --history ~/.ascii-screen/history)
#   ./install.sh --uninstall               stop and remove
# Also links `ascii-screen` into a directory on PATH so --search/--play/--at work from any terminal.
set -euo pipefail
LABEL=com.tetratorus.ascii-screen
APP="$HOME/Applications/ASCII Screen.app"
BIN="$APP/Contents/MacOS/ascii-screen"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/.ascii-screen"
LOG="$HOME/Library/Logs/ascii-screen.log"
DOMAIN="gui/$(id -u)"

CLI_DIRS=("$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin)

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
  for d in "${CLI_DIRS[@]}"; do [[ "$(readlink "$d/ascii-screen" 2>/dev/null)" == "$BIN" ]] && rm -f "$d/ascii-screen"; done
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
# Ad-hoc signatures default to a cdhash requirement, which breaks the Screen Recording grant on every
# rebuild; requiring only the identifier keeps it.
codesign --force --sign - --identifier "$LABEL" -r="designated => identifier \"$LABEL\"" "$APP"

xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; printf '%s' "${s//>/&gt;}"; }
# Frames and history contain whatever was on screen: owner-only.
chmod 700 "$DATA" && chmod -R go-rwx "$DATA"

ARGS=("$@"); [[ ${#ARGS[@]} -eq 0 ]] && ARGS=(--out "$DATA/screen.txt" --history "$DATA/history")
{
  cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$(xml "$BIN")</string>
PL
  for a in "${ARGS[@]}"; do printf '    <string>%s</string>\n' "$(xml "$a")"; done
  cat <<PL
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$(xml "$LOG")</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL
} > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
# Put the CLI on PATH: the first writable directory already on PATH, else ~/.local/bin added to ~/.zshrc.
CLI=""
for d in "${CLI_DIRS[@]}"; do
  [[ ":$PATH:" == *":$d:"* && -d "$d" && -w "$d" ]] && { CLI="$d"; break; }
done
if [[ -z "$CLI" ]]; then
  CLI="$HOME/.local/bin"; mkdir -p "$CLI"
  grep -qs 'ascii-screen PATH' "$HOME/.zshrc" || printf '\nexport PATH="$HOME/.local/bin:$PATH"  # ascii-screen PATH\n' >> "$HOME/.zshrc"
  echo "Added ~/.local/bin to PATH in ~/.zshrc; open a new terminal to use 'ascii-screen'."
fi
ln -sf "$BIN" "$CLI/ascii-screen"

echo "Running as $LABEL. Output: ${ARGS[*]}  Log: $LOG  CLI: $CLI/ascii-screen"
echo "First run: allow 'ASCII Screen' in System Settings > Privacy & Security > Screen Recording; it restarts itself within 30s."
