#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
MODE="release"
if [[ "${1:-}" == "--local-unsigned" ]]; then
  MODE="local-unsigned"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--local-unsigned]" >&2
  exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Camp release packaging only supports Apple silicon (arm64)." >&2
  exit 1
fi

if [[ "$MODE" == "release" ]]; then
  for name in CAMP_APP_SIGN_IDENTITY CAMP_INSTALLER_SIGN_IDENTITY CAMP_NOTARY_PROFILE; do
    if [[ -z "${!name:-}" ]]; then
      echo "Set $name before packaging a public release." >&2
      exit 2
    fi
  done
fi

command -v swift >/dev/null
command -v codesign >/dev/null
command -v pkgbuild >/dev/null
command -v productbuild >/dev/null
command -v xcrun >/dev/null

APP="$ROOT/dist/Camp.app"
SUFFIX="arm64"
if [[ "$MODE" == "local-unsigned" ]]; then SUFFIX="arm64-local-unsigned"; fi
PKG="$ROOT/dist/Camp-$VERSION-$SUFFIX.pkg"
APP_BIN="$APP/Contents/MacOS/Camp"
export CAMP_BUILD_DIR="${CAMP_BUILD_DIR:-$ROOT/.build-release}"
PKG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/camp-package.XXXXXX")"
trap 'rm -rf "$PKG_WORK"' EXIT

swift build --scratch-path "$CAMP_BUILD_DIR" -c release --arch arm64
"$ROOT/scripts/bundle-app.sh"

for binary in "$APP_BIN"; do
  [[ "$(file -b "$binary")" == *"arm64"* ]] || {
    echo "Unexpected non-arm64 executable: $binary" >&2
    exit 1
  }
done

if [[ "$MODE" == "release" ]]; then
  for binary in "$APP_BIN"; do
    codesign --force --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" "$binary"
  done
  codesign --force --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

rm -f "$PKG"
mkdir -p "$PKG_WORK/root/Applications"
ditto "$APP" "$PKG_WORK/root/Applications/Camp.app"
COMPONENT_PKG="$PKG_WORK/Camp-component.pkg"
pkgbuild \
  --root "$PKG_WORK/root" \
  --identifier com.nelmez.camp \
  --version "$VERSION" \
  --install-location / \
  --scripts "$ROOT/scripts/pkg-scripts" \
  --ownership recommended \
  "$COMPONENT_PKG"
if [[ "$MODE" == "release" ]]; then
  productbuild --package "$COMPONENT_PKG" \
    --sign "$CAMP_INSTALLER_SIGN_IDENTITY" \
    "$PKG"
else
  productbuild --package "$COMPONENT_PKG" "$PKG"
fi

if [[ "$MODE" == "release" ]]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$CAMP_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  pkgutil --check-signature "$PKG"
  xcrun stapler validate "$PKG"
  echo "Release package ready: $PKG"
else
  echo "Local unsigned package ready (do not distribute): $PKG"
fi
