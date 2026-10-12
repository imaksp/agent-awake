#!/usr/bin/env bash
# Build Agent Awake, ad-hoc sign it and install it.
#   ./build.sh           build, install to ~/Applications (or $INSTALL_DIR) and launch
#   ./build.sh test      run the transcript-detection tests
#   ./build.sh release   build a universal (Apple silicon + Intel) app and zip it for
#                        a GitHub release, in build/
set -euo pipefail
cd "$(dirname "$0")"

MIN_MACOS=14.0
APP=build/AgentAwake.app
mkdir -p build

# Builds $APP for each architecture given, merged into one binary if more than one.
build_app() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp Resources/Info.plist "$APP/Contents/"
  local slices=()
  for arch in "$@"; do
    swiftc -O -swift-version 6 -target "$arch-apple-macos$MIN_MACOS" -o "build/AgentAwake-$arch" Sources/AgentAwake/*.swift
    slices+=("build/AgentAwake-$arch")
  done
  lipo -create -output "$APP/Contents/MacOS/AgentAwake" "${slices[@]}"
  codesign --force --sign - "$APP"
}

case "${1:-}" in
  test)
    swiftc -O -swift-version 6 -target "$(uname -m)-apple-macos$MIN_MACOS" -o build/tests \
      Sources/AgentAwake/AgentActivity.swift Sources/AgentAwake/Agents.swift Tests/main.swift
    exec build/tests
    ;;
  release)
    build_app arm64 x86_64
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
    zip="build/AgentAwake-$version.zip"
    rm -f "$zip"
    # ditto, not zip: it keeps the bundle's symlinks, permissions and signature intact.
    ditto -c -k --keepParent "$APP" "$zip"
    lipo -archs "$APP/Contents/MacOS/AgentAwake"
    shasum -a 256 "$zip"
    exit 0
    ;;
  "") ;;
  *)
    echo "usage: $0 [test|release]" >&2
    exit 2
    ;;
esac

build_app "$(uname -m)"

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
