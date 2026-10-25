#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO="Nelmez/Camp"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
MODE="release"
if [[ "${1:-}" == "--local-unsigned" ]]; then
  MODE="local-unsigned"
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--local-unsigned]" >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must be a stable semantic version such as 1.0.1." >&2
  exit 2
fi
command -v gh >/dev/null || { echo "Install GitHub CLI (gh) to publish a release." >&2; exit 1; }
gh auth status >/dev/null
gh repo view "$REPO" >/dev/null || {
  echo "Public repository $REPO is not available to the signed-in GitHub account." >&2
  exit 1
}
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
ORIGIN_URL_LOWER="$(printf '%s' "$ORIGIN_URL" | tr '[:upper:]' '[:lower:]')"
if [[ "$ORIGIN_URL_LOWER" != *"github.com/nelmez/camp"* && "$ORIGIN_URL_LOWER" != *"github.com:nelmez/camp"* ]]; then
  echo "Set origin to the public GitHub repository $REPO before publishing." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit the release sources and set VERSION before publishing." >&2
  exit 1
fi
git fetch origin
UPSTREAM="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
if [[ -z "$UPSTREAM" || "$(git rev-parse HEAD)" != "$(git rev-parse "$UPSTREAM")" ]]; then
  echo "Push the current commit to its origin branch before publishing." >&2
  exit 1
fi
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists on $REPO." >&2
  exit 1
fi

if [[ "$MODE" == "local-unsigned" ]]; then
  "$ROOT/scripts/package-installer.sh" --local-unsigned
  "$ROOT/scripts/package-dmg.sh" --local-unsigned
  SUFFIX="arm64-local-unsigned"
  RELEASE_NOTICE="Unsigned preview build. macOS may show Gatekeeper warnings."
else
  "$ROOT/scripts/package-installer.sh"
  "$ROOT/scripts/package-dmg.sh"
  SUFFIX="arm64"
  RELEASE_NOTICE=""
fi

PKG="$ROOT/dist/Camp-${VERSION}-${SUFFIX}.pkg"
DMG="$ROOT/dist/Camp-${VERSION}-${SUFFIX}.dmg"
ZIP="$ROOT/dist/Camp-${VERSION}-arm64.zip"

chmod -R u+w "$ROOT/dist/Camp.app"
xattr -cr "$ROOT/dist/Camp.app"
if [[ "$MODE" != "release" ]]; then
  codesign --force --deep -s - "$ROOT/dist/Camp.app"
fi
codesign --verify --deep --strict --verbose=2 "$ROOT/dist/Camp.app"

rm -f "$ZIP"
(cd "$ROOT/dist" && ditto -c -k --keepParent "Camp.app" "Camp-${VERSION}-arm64.zip")

SPARKLE_BIN="$(find "${CAMP_BUILD_DIR:-$ROOT/.build-release}/artifacts" -type f -name sign_update -print -quit 2>/dev/null || true)"
[[ -x "$SPARKLE_BIN" ]] || {
  echo "Sparkle sign_update was not found. Resolve the Swift package dependencies first." >&2
  exit 1
}
[[ -f "$PKG" && -f "$DMG" && -f "$ZIP" ]] || { echo "Expected package, DMG, or ZIP is missing." >&2; exit 1; }

SIGNATURE="$("$SPARKLE_BIN" -p "$ZIP")"
LENGTH="$(/usr/bin/stat -f '%z' "$ZIP")"
PUB_DATE="$(/bin/date -u '+%a, %d %b %Y %H:%M:%S +0000')"
APPCAST="$ROOT/dist/appcast.xml"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
<channel>
<title>Camp</title>
<link>https://github.com/${REPO}</link>
<description>Stable Camp updates</description>
<language>en</language>
<item>
<title>Camp ${VERSION}</title>
<pubDate>${PUB_DATE}</pubDate>
<sparkle:version>${VERSION}</sparkle:version>
<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/${REPO}/releases/download/v${VERSION}/Camp-${VERSION}-arm64.zip" length="${LENGTH}" type="application/octet-stream" sparkle:edSignature="${SIGNATURE}" />
</item>
</channel>
</rss>
EOF
"$SPARKLE_BIN" "$APPCAST" --disable-signing-warning

NOTES="$ROOT/dist/release-notes.txt"
VERSION_NOTES="$ROOT/release-notes/v${VERSION}.md"
if [[ -f "$VERSION_NOTES" ]]; then
  cp "$VERSION_NOTES" "$NOTES"
else
  cat > "$NOTES" <<EOF
Camp ${VERSION}

Install the DMG for a new installation or to bootstrap the updater. Camp ${VERSION}
and later versions can check this stable GitHub Release feed for updates.
${RELEASE_NOTICE}
EOF
fi

gh release create "v$VERSION" \
  "$PKG#Camp-${VERSION}-${SUFFIX}.pkg" \
  "$DMG#Camp-${VERSION}-${SUFFIX}.dmg" \
  "$ZIP#Camp-${VERSION}-arm64.zip" \
  "$APPCAST#appcast.xml" \
  --repo "$REPO" \
  --title "Camp $VERSION" \
  --notes-file "$NOTES" \
  --latest

echo "Published stable Camp $VERSION to https://github.com/$REPO/releases/tag/v$VERSION"
