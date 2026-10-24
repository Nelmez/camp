#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
PKG="$ROOT/dist/Camp-${VERSION}-arm64-local-unsigned.pkg"
DMG="$ROOT/dist/Camp-${VERSION}-arm64-local-unsigned.dmg"

if [[ ! -f "$PKG" ]]; then
  echo "Unsigned installer package not found: $PKG" >&2
  echo "Build it with ./scripts/package-installer.sh --local-unsigned first." >&2
  exit 1
fi
command -v diskutil >/dev/null

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/camp-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$PKG" "$STAGING/"
cat > "$STAGING/Read Me First.txt" << EOF
Camp ${VERSION} - Apple silicon preview

Install
1. Double-click the Camp-${VERSION}-arm64-local-unsigned.pkg installer.
2. Follow the macOS Installer prompts. Camp is installed in Applications and
   its server runtime is installed under /opt/camp.
3. Open Camp and start the services you need.

Compatibility
This build targets Apple silicon Macs (M1 and later) running macOS 14 or newer.

Unsigned preview notice
This package and app are not signed with a Developer ID certificate and are
not notarized. macOS Gatekeeper may warn or prevent opening them. Only proceed
if you trust the source. Public distribution should use the signed release
package and notarization workflow described in the project README.

The installer includes MariaDB and ProFTPD source archives and license notices
in the installed Camp app bundle under Contents/Resources.
EOF
(cd "$STAGING" && shasum -a 256 "Camp-${VERSION}-arm64-local-unsigned.pkg" > SHA256SUMS.txt)
rm -f "$DMG"
diskutil image create from \
  --format UDZO \
  --volumeName "Camp ${VERSION} Installer" \
  "$STAGING" \
  "$DMG"
echo "Unsigned preview disk image ready: $DMG"
