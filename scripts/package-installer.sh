#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
# shellcheck disable=SC1091
source "$ROOT/stack/versions.env"
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

command -v swift >/dev/null
command -v codesign >/dev/null
command -v pkgbuild >/dev/null
command -v productbuild >/dev/null
command -v xcrun >/dev/null
command -v security >/dev/null

if [[ "$MODE" == "release" ]]; then
  for name in CAMP_APP_SIGN_IDENTITY CAMP_INSTALLER_SIGN_IDENTITY CAMP_NOTARY_PROFILE; do
    if [[ -z "${!name:-}" ]]; then
      echo "Set $name before packaging a public release." >&2
      exit 2
    fi
  done
  identities="$(security find-identity -v -p codesigning 2>/dev/null)"
  app_identity="$(printf '%s\n' "$identities" | grep -F "\"$CAMP_APP_SIGN_IDENTITY\"" || true)"
  installer_identity="$(printf '%s\n' "$identities" | grep -F "\"$CAMP_INSTALLER_SIGN_IDENTITY\"" || true)"
  if [[ "$app_identity" != *"Developer ID Application:"* ]]; then
    echo "CAMP_APP_SIGN_IDENTITY must name a valid Developer ID Application certificate." >&2
    exit 2
  fi
  if [[ "$installer_identity" != *"Developer ID Installer:"* ]]; then
    echo "CAMP_INSTALLER_SIGN_IDENTITY must name a valid Developer ID Installer certificate." >&2
    exit 2
  fi
  app_team="$(printf '%s\n' "$app_identity" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')"
  installer_team="$(printf '%s\n' "$installer_identity" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')"
  if [[ -z "$app_team" || "$app_team" != "$installer_team" ]]; then
    echo "The app and installer certificates must belong to the same Apple Developer team." >&2
    exit 2
  fi
  if ! xcrun notarytool history --keychain-profile "$CAMP_NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "CAMP_NOTARY_PROFILE is not available in the keychain. Create it with xcrun notarytool store-credentials." >&2
    exit 2
  fi
fi

APP="$ROOT/dist/Camp.app"
SUFFIX="arm64"
if [[ "$MODE" == "local-unsigned" ]]; then SUFFIX="arm64-local-unsigned"; fi
PKG="$ROOT/dist/Camp-$VERSION-$SUFFIX.pkg"
APP_BIN="$APP/Contents/MacOS/Camp"
export CAMP_BUILD_DIR="${CAMP_BUILD_DIR:-$ROOT/.build-release}"
PKG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/camp-package.XXXXXX")"
trap 'rm -rf "$PKG_WORK"' EXIT

"$ROOT/scripts/build-stack.sh"

swift build --scratch-path "$CAMP_BUILD_DIR" -c release --arch arm64
"$ROOT/scripts/bundle-app.sh"
"$ROOT/scripts/stage-third-party-licenses.sh" \
  "$APP/Contents/Resources/THIRD_PARTY_LICENSES"

PMA_ARCHIVE="$ROOT/build/cache/phpmyadmin-${PHPMYADMIN_VERSION}.tar.xz"
if [[ ! -f "$PMA_ARCHIVE" ]]; then
  mkdir -p "$(dirname "$PMA_ARCHIVE")"
  curl -fL --retry 5 --retry-delay 2 \
    -o "$PMA_ARCHIVE.partial" \
    "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.xz"
  mv "$PMA_ARCHIVE.partial" "$PMA_ARCHIVE"
fi
cp "$PMA_ARCHIVE" "$APP/Contents/Resources/Camp/stack/phpmyadmin.tar.xz"

SOURCE_DIR="$APP/Contents/Resources/THIRD_PARTY_SOURCES"
mkdir -p "$SOURCE_DIR"
for source in \
  "mariadb-${MARIADB_VERSION}.tar.gz|https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz" \
  "proftpd-${PROFTPD_VERSION}.tar.gz|https://github.com/proftpd/proftpd/archive/refs/tags/v${PROFTPD_VERSION}.tar.gz"; do
  archive="${source%%|*}"
  url="${source#*|}"
  cached="$ROOT/build/cache/$archive"
  if [[ ! -f "$cached" ]]; then
    curl -fL --retry 5 --retry-delay 2 -o "$cached.partial" "$url"
    mv "$cached.partial" "$cached"
  fi
  cp "$cached" "$SOURCE_DIR/$archive"
done
cat > "$SOURCE_DIR/README.txt" << EOF
Corresponding source archives for Camp's redistributed GPL software.

MariaDB Server ${MARIADB_VERSION} (GPL-2.0-only):
  mariadb-${MARIADB_VERSION}.tar.gz
  https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz

ProFTPD ${PROFTPD_VERSION} (GPL-2.0-or-later):
  proftpd-${PROFTPD_VERSION}.tar.gz
  https://github.com/proftpd/proftpd/archive/refs/tags/v${PROFTPD_VERSION}.tar.gz

phpMyAdmin ${PHPMYADMIN_VERSION} (GPL-2.0-or-later) source is included at:
  Camp/stack/phpmyadmin.tar.xz
  https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.xz

SHA-256 checksums:
EOF
(cd "$SOURCE_DIR" && shasum -a 256 *.tar.gz | awk '{print "  " $1 "  " $2}') \
  >> "$SOURCE_DIR/README.txt"

for binary in "$APP_BIN"; do
  [[ "$(file -b "$binary")" == *"arm64"* ]] || {
    echo "Unexpected non-arm64 executable: $binary" >&2
    exit 1
  }
done

if [[ "$MODE" == "release" ]]; then
  codesign --force --deep --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" \
    "$APP/Contents/Frameworks/Sparkle.framework"
  for binary in "$APP_BIN"; do
    codesign --force --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" "$binary"
  done
  codesign --force --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

rm -f "$PKG"
mkdir -p "$PKG_WORK/root/Applications"
ditto "$APP" "$PKG_WORK/root/Applications/Camp.app"
mkdir -p "$PKG_WORK/root/opt/camp"
for component in bin sbin lib libexec modules share conf etc htdocs icons error cgi-bin php scripts support-files; do
  if [[ -e "/opt/camp/$component" ]]; then
    ditto "/opt/camp/$component" "$PKG_WORK/root/opt/camp/$component"
  fi
done
mkdir -p "$PKG_WORK/root/opt/camp/var"
chmod 777 "$PKG_WORK/root/opt/camp/var"
find "$PKG_WORK/root/opt/camp" -depth \( -name '._*' -o -name '.DS_Store' \) -exec rm -rf {} +
rm -f "$PKG_WORK/root/opt/camp/bin/bison"
rm -rf "$PKG_WORK/root/opt/camp/share/bison"
rm -f "$PKG_WORK/root/opt/camp/modules/mod_brotli.so"
rm -f "$PKG_WORK/root/opt/camp/modules/mod_http2.so"

while IFS= read -r binary; do
  description="$(file -b "$binary")"
  case "$description" in
    *Mach-O*)
      [[ "$description" == *arm64* ]] || {
        echo "Non-arm64 code found in the runtime payload: $binary ($description)" >&2
        exit 1
      }
      bad_deps="$(otool -L "$binary" 2>/dev/null | grep -E '/opt/homebrew|/usr/local' || true)"
      if [[ -n "$bad_deps" ]]; then
        echo "Non-system code dependency found in runtime payload: $binary ($bad_deps)" >&2
        exit 1
      fi
      if [[ "$MODE" == "release" ]]; then
        codesign --force --timestamp --options runtime --sign "$CAMP_APP_SIGN_IDENTITY" "$binary"
        codesign --verify --strict --verbose=2 "$binary"
      fi
      ;;
  esac
done < <(find "$PKG_WORK/root/opt/camp" -type f -print)

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
