#!/bin/sh
set -eu
case "${1:-}" in
  ""|--no-install) ;;
  *) echo "usage: $0 [--no-install]" >&2; exit 2 ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/Build/Products/Release/Hinge.app"
cd "$ROOT"
# Xcode and the command line use the same generated project and Info.plist.
xcodegen generate
xcodebuild -project Hinge.xcodeproj -scheme Hinge -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$ROOT/build" \
  CODE_SIGN_IDENTITY=- build -quiet
codesign --verify --deep --strict "$OUT"

# Stage and verify beside the destination, then swap in one rename(2) so the app path never disappears.
# Shell has no RENAME_SWAP; a first install uses RENAME_EXCL instead.
install_app() {
  STAGED="$(dirname "$2")/.hinge-install.$$"
  rm -rf "$STAGED"
  if ditto "$1" "$STAGED" && codesign --verify --deep --strict "$STAGED" &&
    xcrun swift -e 'import Darwin; let a = CommandLine.arguments
      exit(renamex_np(a[1], a[2], UInt32(RENAME_SWAP)) == 0 ||
        (errno == ENOENT && renamex_np(a[1], a[2], UInt32(RENAME_EXCL)) == 0) ? 0 : 1)' "$STAGED" "$2"; then
    rm -rf "$STAGED"
  else
    rm -rf "$STAGED"
    echo "Hinge installation failed: $2 left unchanged" >&2
    exit 1
  fi
}

install_app "$OUT" "$ROOT/Hinge.app"
echo "built: $ROOT/Hinge.app"
if [ "${1:-}" != --no-install ]; then
  install_app "$OUT" /Applications/Hinge.app
  echo "installed: /Applications/Hinge.app"
fi
