#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
MODE="release"
if [[ "${1:-}" == "--local-unsigned" ]]; then
  MODE="local-unsigned"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--local-unsigned]" >&2
  exit 2
fi
SUFFIX="arm64"
if [[ "$MODE" == "local-unsigned" ]]; then SUFFIX="arm64-local-unsigned"; fi
PKG="$ROOT/dist/Camp-${VERSION}-${SUFFIX}.pkg"
DMG="$ROOT/dist/Camp-${VERSION}-${SUFFIX}.dmg"

if [[ ! -f "$PKG" ]]; then
  echo "Installer package not found: $PKG" >&2
  if [[ "$MODE" == "local-unsigned" ]]; then
    echo "Build it with ./scripts/package-installer.sh --local-unsigned first." >&2
  else
    echo "Build it with ./scripts/package-installer.sh first." >&2
  fi
  exit 1
fi
command -v diskutil >/dev/null

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/camp-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
cp "$PKG" "$STAGING/"
cat > "$STAGING/Read Me First.txt" << EOF
Camp ${VERSION} - Apple silicon installer

Install
1. Double-click the Camp-${VERSION}-${SUFFIX}.pkg installer.
2. Follow the macOS Installer prompts. Camp is installed in Applications and
   its server runtime is installed under /opt/camp.
3. Open Camp and start the services you need.

Compatibility
This build targets Apple silicon Macs (M1 and later) running macOS 14 or newer.

EOF
if [[ "$MODE" == "local-unsigned" ]]; then
  cat >> "$STAGING/Read Me First.txt" << EOF

Unsigned preview notice
This package and app are not signed with a Developer ID certificate and are
not notarized. macOS Gatekeeper may warn or prevent opening them. Only proceed
if you trust the source. See the project README for signed distribution.
EOF
fi
cat >> "$STAGING/Read Me First.txt" << EOF

The installer includes MariaDB and ProFTPD source archives and license notices
in the installed Camp app bundle under Contents/Resources.
EOF
(cd "$STAGING" && shasum -a 256 "Camp-${VERSION}-${SUFFIX}.pkg" > SHA256SUMS.txt)
rm -f "$DMG"
diskutil image create from \
  --format UDZO \
  --volumeName "Camp ${VERSION} Installer" \
  "$STAGING" \
  "$DMG"
echo "Installer disk image ready: $DMG"
