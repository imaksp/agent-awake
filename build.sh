#!/usr/bin/env bash
# Build Agent Awake, ad-hoc sign it and install it.
#   ./build.sh           build, install to ~/Applications (or $INSTALL_DIR) and launch
#   ./build.sh test      run the transcript-detection tests
set -euo pipefail
cd "$(dirname "$0")"

TARGET="$(uname -m)-apple-macos14.0"
mkdir -p build

if [ "${1:-}" = test ]; then
  swiftc -O -swift-version 6 -target "$TARGET" -o build/tests \
    Sources/AgentAwake/AgentActivity.swift Sources/AgentAwake/Agents.swift Tests/main.swift
  exec build/tests
fi

APP=build/AgentAwake.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/"
swiftc -O -swift-version 6 -target "$TARGET" -o "$APP/Contents/MacOS/AgentAwake" Sources/AgentAwake/*.swift
codesign --force --sign - "$APP"

DEST="${INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DEST"
# SIGTERM makes a running copy quit cleanly, restoring sleep before it is replaced.
# One stuck behind an open password prompt is killed after 10s; its watchdog then
# restores sleep.
if pkill -x AgentAwake; then
  for _ in $(seq 50); do pgrep -x AgentAwake >/dev/null || break; sleep 0.2; done
  if pkill -9 -x AgentAwake; then
    while pgrep -x AgentAwake >/dev/null; do sleep 0.2; done
  fi
fi
rm -rf "$DEST/AgentAwake.app"
ditto "$APP" "$DEST/AgentAwake.app"
open "$DEST/AgentAwake.app"
echo "Installed $DEST/AgentAwake.app"
