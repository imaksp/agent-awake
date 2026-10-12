#!/usr/bin/env bash
# Build Agent Awake, ad-hoc sign it and install it.
#   ./build.sh           build, install to ~/Applications (or $INSTALL_DIR) and launch
#   ./build.sh test      run the transcript-detection tests
#   ./build.sh release   build a universal (Apple silicon + Intel) app and zip it for
#                        a GitHub release, in build/
#   ./build.sh publish X.Y.Z
#                        set the version, commit, tag vX.Y.Z and push; the Release
#                        workflow on GitHub builds and publishes it
set -euo pipefail
cd "$(dirname "$0")"

MIN_MACOS=14.0
APP=build/AgentAwake.app
mkdir -p build

die() {
  echo "$*" >&2
  exit 1
}

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
  publish)
    version="${2:-}"
    number='(0|[1-9][0-9]*)'
    [[ "$version" =~ ^$number\.$number\.$number$ ]] || die "usage: $0 publish X.Y.Z"
    tag="v$version"
    plist=Resources/Info.plist
    current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
    [ "$(git branch --show-current)" = main ] || die "Publish from main."
    [ -z "$(git status --porcelain)" ] || die "Commit or stash your changes first."
    git fetch --quiet --tags origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main isn't in sync with origin/main."
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "$tag already exists."
    newest=$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [ "$newest" = "$version" ] && [ "$version" != "$current" ] || die "$version isn't newer than $current."
    "./$(basename "$0")" test  # we're in the script's folder after the cd above
    build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
    # The push is atomic, so the tag never reaches GitHub without the commit that sets
    # its version. If any step fails, undo the local commit and tag: the checks above
    # guarantee the checkout matched origin/main with nothing uncommitted.
    if ! {
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $((build + 1))" "$plist" \
        && git commit -q -m "chore: release $tag" "$plist" \
        && git tag -a "$tag" -m "Agent Awake $version" \
        && git push --atomic origin main "$tag"
    }; then
      git tag -d "$tag" >/dev/null 2>&1 || true
      git reset -q --hard origin/main
      die "Publishing $tag failed, so the local release commit and tag were undone." \
        "If the push may have got through anyway, check GitHub before retrying."
    fi
    echo "Pushed $tag. The Release workflow on GitHub builds and publishes it."
    exit 0
    ;;
  "") ;;
  *)
    echo "usage: $0 [test|release|publish X.Y.Z]" >&2
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
