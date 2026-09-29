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
  -o "$TEST_DIR/hinge-tests"
"$TEST_DIR/hinge-tests" "$TEST_DIR/state" suite
