#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Usage: stage-third-party-licenses.sh DESTINATION}"
# shellcheck disable=SC1091
source "$ROOT/stack/versions.env"

mkdir -p "$DEST"

copy_component() {
  local component="$1" folder="$2" extra="${3:-}"
  local source=""
  local candidate
  for candidate in "/opt/camp/var/src/$folder" "$ROOT/build/src/$folder" "$extra"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then source="$candidate"; break; fi
  done
  [[ -n "$source" ]] || { echo "Missing source tree for third-party licenses: $component ($folder)" >&2; return 1; }

  local found=0 file relative target
  while IFS= read -r file; do
    found=1
    relative="${file#"$source"/}"
    target="$DEST/$component/$relative"
    mkdir -p "$(dirname "$target")"
    cp "$file" "$target"
  done < <(find "$source" -maxdepth 3 -type f ! -name '._*' \( \
      -iname 'license*' -o -iname 'licence*' -o -iname 'copying*' \
      -o -iname 'notice*' -o -iname 'artistic' -o -iname 'copyright*' \
      -o -iname 'copying' \) -print)
  if [[ $found -eq 0 ]]; then
    echo "No license files found for third-party component: $component ($source)" >&2
    return 1
  fi
}

copy_component Apache-httpd "httpd-$HTTPD_VERSION"
copy_component APR "apr-$APR_VERSION"
copy_component APR-util "apr-util-$APR_UTIL_VERSION"
copy_component OpenSSL "openssl-$OPENSSL_VERSION" "$ROOT/build/src/openssl-$OPENSSL_VERSION"
copy_component PCRE2 "pcre2-$PCRE2_VERSION"
copy_component PHP "php-$PHP_VERSION"
copy_component MariaDB "mariadb-$MARIADB_VERSION"
copy_component Perl "perl-$PERL_VERSION"
copy_component ProFTPD "proftpd-$PROFTPD_VERSION"
copy_component phpMyAdmin "phpmyadmin-source" "/Library/Application Support/Camp/htdocs/phpmyadmin"
copy_component libpng "libpng-$LIBPNG_VERSION"
copy_component libjpeg-turbo "libjpeg-turbo-$LIBJPEG_VERSION"
copy_component FreeType "freetype-$FREETYPE_VERSION"
copy_component libzip "libzip-$LIBZIP_VERSION"
copy_component Oniguruma "onig-$ONIG_VERSION"
copy_component ICU "icu"
copy_component GNU-Bison "bison-$BISON_VERSION" "$ROOT/build/src/bison-$BISON_VERSION"

echo "Staged third-party license files in $DEST"
