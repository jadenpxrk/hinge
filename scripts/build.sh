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
xcrun swiftc -module-cache-path "$ROOT/build/ModuleCache.noindex" \
  "$ROOT/scripts/install.swift" -o "$ROOT/build/hinge-install"
"$ROOT/build/hinge-install" "$OUT" "$ROOT/Hinge.app"
echo "built: $ROOT/Hinge.app"
if [ "${1:-}" != --no-install ]; then
  "$ROOT/build/hinge-install" "$OUT" /Applications/Hinge.app
  echo "installed: /Applications/Hinge.app"
fi
