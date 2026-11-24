#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export CARGO_TARGET_DIR="${ROOT}/target"

# One deployment target for the Rust objects and the Swift binary. It matches
# LSMinimumSystemVersion in Info.plist.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

APP="dist/SuperSurfer.app"
MACOS="$APP/Contents/MacOS"
SOURCES="packaging/macos/app"
CORE="target/release/libsupersurfer.a"
CORE_LIBS="target/release/libsupersurfer.native-libs"

# The app is one executable: Swift for everything macOS-specific, with the
# Rust core linked in as a static library. The crate type is chosen here
# rather than in Cargo.toml so other platforms do not build an archive they
# never use.
echo "Building Rust core (static library)..."
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  cargo rustc --release --lib --crate-type staticlib -- --print native-static-libs 2>&1 \
  | tee "$BUILD_LOG"

# rustc names the system libraries the archive depends on, but only when it
# actually links. On an unchanged tree it prints nothing, so keep its last
# answer next to the archive. The note may be wrapped in colour codes (CI sets
# CARGO_TERM_COLOR=always); strip them, or the last flag ends in "ESC[0m".
NATIVE_LIBS="$(sed -n 's/^.*native-static-libs: //p' "$BUILD_LOG" | tail -n 1 | sed $'s/\033\\[[0-9;]*m//g')"
if [ -n "$NATIVE_LIBS" ]; then
  printf '%s\n' "$NATIVE_LIBS" > "$CORE_LIBS"
elif [ -f "$CORE_LIBS" ]; then
  NATIVE_LIBS="$(cat "$CORE_LIBS")"
else
  NATIVE_LIBS="-liconv -lproc"
fi
# swiftc links libSystem itself; naming it again only earns a linker warning.
NATIVE_LIBS="${NATIVE_LIBS//-lSystem/}"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp packaging/macos/Info.plist "$APP/Contents/Info.plist"

echo "Compiling SuperSurfer.app..."
# NATIVE_LIBS is a list of linker flags and must be split into words.
# shellcheck disable=SC2086
swiftc -O -wmo -swift-version 5 \
  -target "$(uname -m)-apple-macos${DEPLOYMENT_TARGET}" \
  -import-objc-header "$SOURCES/supersurfer.h" \
  "$SOURCES"/*.swift \
  "$CORE" $NATIVE_LIBS \
  -framework Cocoa \
  -framework ServiceManagement \
  -Xlinker -dead_strip \
  -o "$MACOS/SuperSurfer"
chmod +x "$MACOS/SuperSurfer"

# The helper uses an API that arrived with macOS 12. Without an explicit
# target it would only run on the build machine's macOS version or newer.
swiftc packaging/macos/set-default.swift \
  -target "$(uname -m)-apple-macos12.0" \
  -o "$MACOS/set-default" \
  -framework AppKit \
  -framework Foundation \
  -O
chmod +x "$MACOS/set-default"

# Ad-hoc signature by default. Set CODESIGN_IDENTITY to a "Developer ID
# Application: ..." identity for a build that can be notarized; that needs the
# hardened runtime and a secure timestamp.
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
  else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  fi
fi

echo "Built $APP"
echo "Install:  cp -R '$APP' /Applications/"
echo "Register: /Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer register"
echo "Start:    open -a SuperSurfer   (stays in the menu bar; register starts it too)"
