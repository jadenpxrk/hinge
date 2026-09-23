#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hinge-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# Explicit compile-time system boundary: no source rewriting or real power changes.
xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" -framework AppKit \
  "$ROOT/Hinge/Engine.swift" "$ROOT/Hinge/SessionController.swift" \
  "$ROOT/Hinge/CloseGesture.swift" "$ROOT/Hinge/Support.swift" \
  "$ROOT/Hinge/AppDelegate.swift" "$ROOT/Hinge/SettingsWindow.swift" \
  "$ROOT/Tests/SystemStubs.swift" "$ROOT/Tests/main.swift" \
  -o "$TEST_DIR/hinge & tests"
"$TEST_DIR/hinge & tests" "$TEST_DIR/state" suite

# Exercise real bundle copies and signature checks, only in the temporary directory.
xcrun swiftc -module-cache-path "$TEST_DIR/ModuleCache" \
  "$ROOT/scripts/install.swift" -o "$TEST_DIR/install"
SOURCE="$TEST_DIR/source.app"
DESTINATION="$TEST_DIR/Applications & Apps/Hinge.app"
mkdir -p "$SOURCE/Contents/MacOS" "$SOURCE/Contents/Resources" "$(dirname "$DESTINATION")"
cp /usr/bin/true "$SOURCE/Contents/MacOS/Hinge"
cat > "$SOURCE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.hinge.install-test</string>
<key>CFBundleExecutable</key><string>Hinge</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
echo old > "$SOURCE/Contents/Resources/version"
touch "$SOURCE/Contents/Resources/obsolete"
codesign --force --sign - "$SOURCE"
"$TEST_DIR/install" "$SOURCE" "$DESTINATION"
test "$(cat "$DESTINATION/Contents/Resources/version")" = old
rm "$SOURCE/Contents/Resources/obsolete"
echo new > "$SOURCE/Contents/Resources/version"
codesign --force --sign - "$SOURCE"
"$TEST_DIR/install" "$SOURCE" "$DESTINATION"
test "$(cat "$DESTINATION/Contents/Resources/version")" = new
test ! -e "$DESTINATION/Contents/Resources/obsolete"
echo tampered > "$SOURCE/Contents/Resources/version"
for INVALID_SOURCE in "$TEST_DIR/missing.app" "$SOURCE"; do
  if "$TEST_DIR/install" "$INVALID_SOURCE" "$DESTINATION" > "$TEST_DIR/install-error" 2>&1; then
    echo "FAIL: installer accepted missing or tampered source" >&2
    exit 1
  fi
  test "$(cat "$DESTINATION/Contents/Resources/version")" = new
  codesign --verify --deep --strict "$DESTINATION"
done
for LEFTOVER in "$(dirname "$DESTINATION")"/.hinge-install-*; do
  test ! -e "$LEFTOVER"
done
echo "PASS: fresh install, bundle replacement, and preservation after copy/signature failures"
