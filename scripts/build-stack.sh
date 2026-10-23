#!/bin/bash
# Builds the Camp server tree into /opt/camp and links it from
# /Library/Application Support/Camp/stack. The compiled prefix cannot contain
# spaces; PHP's apxs and several configure scripts split on them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/stack/versions.env"

PREFIX="/opt/camp"
DATA="/Library/Application Support/Camp"
JOBS="$(getconf _NPROCESSORS_ONLN)"
if [[ -n "${CAMP_CACHE_DIR:-}" ]]; then
  CACHE="$CAMP_CACHE_DIR"
elif [[ -w "$ROOT" ]]; then
  CACHE="$ROOT/build/cache"
else
  CACHE="$HOME/Library/Caches/Camp/downloads"
fi
# Object trees cannot live under a path that contains spaces. apr, PHP, and libtool split on them.
SRC="/opt/camp/var/src"
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "Camp release builds require an Apple silicon Mac (arm64)." >&2
  exit 1
fi
OPENSSL_TARGET="darwin64-arm64-cc"

export PATH="$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I$PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L$PREFIX/lib${LDFLAGS:+ $LDFLAGS}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

for tool in curl tar make cmake xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Camp needs '$tool' to build its server stack. Install Xcode Command Line Tools and CMake, then try again." >&2
    exit 1
  fi
done
if ! xcrun --show-sdk-path >/dev/null 2>&1; then
  echo "Camp could not find the macOS SDK. Install or select Xcode Command Line Tools, then try again." >&2
  exit 1
fi

mkdir -p "$CACHE" "$SRC"
trap 'echo "Build failed near line $LINENO" >&2' ERR

fix_icu_install_names() {
  local lib dep
  [[ -d "$PREFIX/lib" ]] || return 0
  for lib in "$PREFIX"/lib/libicu*.*.*.dylib; do
    [[ -f "$lib" && ! -L "$lib" ]] || continue
    install_name_tool -id "$lib" "$lib"
  done
  for lib in "$PREFIX"/lib/libicu*.*.*.dylib; do
    [[ -f "$lib" && ! -L "$lib" ]] || continue
    while IFS= read -r dep; do
      case "$dep" in
        libicu*) install_name_tool -change "$dep" "$PREFIX/lib/$dep" "$lib" ;;
      esac
    done < <(otool -L "$lib" | awk 'NR>1 {print $1}')
  done
  if otool -L "$PREFIX"/lib/libicu*.*.*.dylib 2>/dev/null | awk 'NR>1 {print $1}' | grep -q '^libicu'; then
    echo "ICU libraries still have relative install names" >&2
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$DATA/htdocs/cgi-bin" "$DATA/conf" "$DATA/logs" "$DATA/data/mysql" "$DATA/ftp" "$DATA/tmp" "$DATA/run" 2>/dev/null || true
  if [[ -w "$PREFIX" && -w "$DATA" ]]; then
    mkdir -p "$PREFIX" "$DATA/htdocs/cgi-bin" "$DATA/conf" "$DATA/logs" "$DATA/data/mysql" "$DATA/ftp" "$DATA/tmp" "$DATA/run"
    ln -sfn "$PREFIX" "$DATA/stack"
    return
  fi
  local cmd
  cmd="mkdir -p '$PREFIX' '$DATA/htdocs/cgi-bin' '$DATA/conf' '$DATA/logs' '$DATA/data/mysql' '$DATA/ftp' '$DATA/tmp' '$DATA/run' && chown -R '$USER:$(id -gn)' '$PREFIX' '$DATA' && chmod 755 '$PREFIX' '$DATA' && ln -sfn '$PREFIX' '$DATA/stack'"
  if sudo -n true 2>/dev/null; then
    sudo bash -c "$cmd"
    return
  fi
  echo "macOS needs an administrator password to create $PREFIX and $DATA."
  osascript -e "do shell script \"$cmd\" with administrator privileges"
}

fetch() {
  local url="$1" name="$2"
  if [[ -f "$CACHE/$name" ]]; then
    echo "cached $name"
    return
  fi
  echo "fetch $name"
  curl -fL --retry 5 --retry-delay 2 -o "$CACHE/$name.partial" "$url"
  mv "$CACHE/$name.partial" "$CACHE/$name"
}

unpack() {
  local archive="$1"
  local top
  set +o pipefail
  top="$(tar -tf "$CACHE/$archive" | head -1 | cut -d/ -f1)"
  set -o pipefail
  if [[ -d "$SRC/$top" ]]; then
    printf '%s\n' "$top"
    return
  fi
  tar -xf "$CACHE/$archive" -C "$SRC"
  printf '%s\n' "$top"
}

cmake_install() {
  local source="$1"
  shift
  rm -rf "$source/build-camp"
  cmake -S "$source" -B "$source/build-camp" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    "$@"
  cmake --build "$source/build-camp" -j "$JOBS"
  cmake --install "$source/build-camp"
}

ensure_dirs

if [[ ! -x "$PREFIX/bin/bison" ]]; then
  fetch "https://ftp.gnu.org/gnu/bison/bison-${BISON_VERSION}.tar.gz" "bison-${BISON_VERSION}.tar.gz"
  dir="$(unpack "bison-${BISON_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure --prefix="$PREFIX"
  make -j "$JOBS"
  make install
  popd >/dev/null
  hash -r
fi

if [[ ! -x "$PREFIX/bin/openssl" ]]; then
  fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}.tar.gz"
  dir="$(unpack "openssl-${OPENSSL_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./Configure "$OPENSSL_TARGET" shared no-tests zlib --prefix="$PREFIX" --libdir=lib --openssldir="$PREFIX/ssl"
  make -j "$JOBS"
  make install_sw
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/bin/apr-1-config" ]]; then
  fetch "https://archive.apache.org/dist/apr/apr-${APR_VERSION}.tar.gz" "apr-${APR_VERSION}.tar.gz"
  dir="$(unpack "apr-${APR_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure --prefix="$PREFIX"
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/bin/apu-1-config" ]]; then
  fetch "https://archive.apache.org/dist/apr/apr-util-${APR_UTIL_VERSION}.tar.gz" "apr-util-${APR_UTIL_VERSION}.tar.gz"
  rm -rf "$SRC/apr-util-${APR_UTIL_VERSION}"
  dir="$(unpack "apr-util-${APR_UTIL_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  SDK="$(xcrun --show-sdk-path)"
  ./configure --prefix="$PREFIX" --with-apr="$PREFIX" --with-openssl="$PREFIX" --with-expat="$SDK/usr"
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/bin/pcre2-config" ]]; then
  fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}.tar.gz"
  dir="$(unpack "pcre2-${PCRE2_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure --prefix="$PREFIX" --enable-jit --enable-shared --disable-static
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -f "$PREFIX/lib/libpng.dylib" && ! -f "$PREFIX/lib/libpng16.dylib" ]]; then
  fetch "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" "libpng-${LIBPNG_VERSION}.tar.gz"
  dir="$(unpack "libpng-${LIBPNG_VERSION}.tar.gz")"
  cmake_install "$SRC/$dir" -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF
fi

if [[ ! -f "$PREFIX/lib/libjpeg.dylib" ]]; then
  fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_VERSION}/libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz" "libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz"
  dir="$(unpack "libjpeg-turbo-${LIBJPEG_VERSION}.tar.gz")"
  cmake_install "$SRC/$dir" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_JPEG8=ON
fi

if [[ ! -f "$PREFIX/lib/libfreetype.dylib" ]]; then
  fetch "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" "freetype-${FREETYPE_VERSION}.tar.xz"
  dir="$(unpack "freetype-${FREETYPE_VERSION}.tar.xz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure --prefix="$PREFIX" --enable-freetype-config --without-harfbuzz --without-brotli --without-png
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -f "$PREFIX/lib/libzip.dylib" ]]; then
  fetch "https://github.com/nih-at/libzip/archive/refs/tags/v${LIBZIP_VERSION}.tar.gz" "libzip-${LIBZIP_VERSION}.tar.gz"
  dir="$(unpack "libzip-${LIBZIP_VERSION}.tar.gz")"
  cmake_install "$SRC/$dir" -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DENABLE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$PREFIX"
fi

if [[ ! -x "$PREFIX/bin/httpd" ]]; then
  fetch "https://archive.apache.org/dist/httpd/httpd-${HTTPD_VERSION}.tar.gz" "httpd-${HTTPD_VERSION}.tar.gz"
  dir="$(unpack "httpd-${HTTPD_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure \
    --prefix="$PREFIX" \
    --enable-so \
    --enable-ssl \
    --with-ssl="$PREFIX" \
    --enable-cgi \
    --enable-rewrite \
    --enable-mods-shared=most \
    --with-mpm=prefork \
    --with-apr="$PREFIX" \
    --with-apr-util="$PREFIX" \
    --with-pcre="$PREFIX"
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -f "$PREFIX/lib/.camp-icu-ids" ]]; then
  rm -f "$PREFIX"/lib/libicu* "$PREFIX"/lib/pkgconfig/icu*.pc
  rm -rf "$PREFIX/include/unicode" "$PREFIX/lib/icu" "$SRC/icu"
  icu_tag="${ICU_VERSION//./-}"
  icu_file="icu4c-${ICU_VERSION//./_}-src.tgz"
  fetch "https://github.com/unicode-org/icu/releases/download/release-${icu_tag}/${icu_file}" "$icu_file"
  dir="$(unpack "$icu_file")"
  pushd "$SRC/$dir/source" >/dev/null
  LDFLAGS="$LDFLAGS -Wl,-headerpad_max_install_names" \
    ./configure --prefix="$PREFIX" --disable-samples --disable-tests --enable-rpath
  make -j "$JOBS"
  make install
  popd >/dev/null
  fix_icu_install_names
  touch "$PREFIX/lib/.camp-icu-ids"
fi

if [[ ! -f "$PREFIX/lib/libonig.dylib" ]]; then
  fetch "https://github.com/kkos/oniguruma/releases/download/v${ONIG_VERSION}/onig-${ONIG_VERSION}.tar.gz" "onig-${ONIG_VERSION}.tar.gz"
  rm -rf "$SRC/onig-${ONIG_VERSION}"
  dir="$(unpack "onig-${ONIG_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure --prefix="$PREFIX" --enable-shared --disable-static
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/bin/php" ]]; then
  fetch "https://www.php.net/distributions/php-${PHP_VERSION}.tar.gz" "php-${PHP_VERSION}.tar.gz"
  rm -rf "$SRC/php-${PHP_VERSION}"
  dir="$(unpack "php-${PHP_VERSION}.tar.gz")"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export DYLD_LIBRARY_PATH="$PREFIX/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export LDFLAGS="-L$PREFIX/lib -Wl,-rpath,$PREFIX/lib"
  pushd "$SRC/$dir" >/dev/null
  php_args=(
    --prefix="$PREFIX"
    --with-apxs2="$PREFIX/bin/apxs"
    --enable-mysqlnd
    --with-mysqli
    --with-pdo-mysql=mysqlnd
    --with-openssl="$PREFIX"
    --with-iconv="$(xcrun --show-sdk-path)/usr"
    --with-curl
    --with-zlib
    --enable-mbstring
    --with-zip="$PREFIX"
    --enable-gd
    --with-jpeg="$PREFIX"
    --with-freetype="$PREFIX"
    --enable-opcache
    --without-pear
    --disable-cgi
    --disable-phpdbg
  )
  ./configure "${php_args[@]}" --enable-intl
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/bin/perl" ]]; then
  fetch "https://www.cpan.org/src/5.0/perl-${PERL_VERSION}.tar.gz" "perl-${PERL_VERSION}.tar.gz"
  dir="$(unpack "perl-${PERL_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./Configure -des -Dprefix="$PREFIX" -Dvendorprefix="$PREFIX" -Duseshrplib -Dusethreads -Accflags="-O2"
  make -j "$JOBS"
  make install
  popd >/dev/null
fi

if [[ ! -x "$PREFIX/sbin/mariadbd" && ! -x "$PREFIX/bin/mariadbd" ]]; then
  fetch "https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/source/mariadb-${MARIADB_VERSION}.tar.gz" "mariadb-${MARIADB_VERSION}.tar.gz"
  dir="$(unpack "mariadb-${MARIADB_VERSION}.tar.gz")"
  hash -r
  sdkroot="$(xcrun --show-sdk-path)"
  mkdir -p "$SRC/zlib-include"
  ln -sfn "$sdkroot/usr/include/zlib.h" "$SRC/zlib-include/zlib.h"
  ln -sfn "$sdkroot/usr/include/zconf.h" "$SRC/zlib-include/zconf.h"
  (
    unset CPPFLAGS CFLAGS CXXFLAGS CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
    export SDKROOT="$sdkroot"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    cmake_install "$SRC/$dir" \
      -DOPENSSL_ROOT_DIR="$PREFIX" \
      -DWITH_SSL="$PREFIX" \
      -DWITH_ZLIB=system \
      -DZLIB_INCLUDE_DIR="$SRC/zlib-include" \
      -DZLIB_LIBRARY="$sdkroot/usr/lib/libz.tbd" \
      -DLIBXML2_INCLUDE_DIR="$sdkroot/usr/include/libxml2" \
      -DLIBXML2_LIBRARY="$sdkroot/usr/lib/libxml2.tbd" \
      -DPCRE2_INCLUDE_DIR="$PREFIX/include" \
      -DPCRE2_LIBRARY="$PREFIX/lib/libpcre2-8.dylib" \
      -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
      -DPLUGIN_ROCKSDB=NO \
      -DPLUGIN_MROONGA=NO \
      -DPLUGIN_TOKUDB=NO \
      -DPLUGIN_SPIDER=NO \
      -DPLUGIN_OQGRAPH=NO \
      -DPLUGIN_COLUMNSTORE=NO \
      -DPLUGIN_SPHINX=NO \
      -DPLUGIN_S3=NO \
      -DWITH_UNIT_TESTS=OFF \
      -DWITH_EMBEDDED_SERVER=OFF \
      -DCONC_WITH_UNIT_TESTS=OFF \
      -DWITH_JEMALLOC=NO \
      -DENABLE_DTRACE=OFF \
      -DWITH_SAFEMALLOC=OFF \
      -DMYSQL_MAINTAINER_MODE=OFF \
      -DSECURITY_HARDENED=OFF \
      -DWITH_PCRE=system \
      -DBISON_EXECUTABLE="$PREFIX/bin/bison" \
      -DCMAKE_OSX_SYSROOT="$sdkroot" \
      -DCMAKE_C_FLAGS="-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION" \
      -DCMAKE_CXX_FLAGS="-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION"
  )
fi

if [[ ! -x "$PREFIX/sbin/proftpd" && ! -x "$PREFIX/bin/proftpd" ]]; then
  fetch "https://github.com/proftpd/proftpd/archive/refs/tags/v${PROFTPD_VERSION}.tar.gz" "proftpd-${PROFTPD_VERSION}.tar.gz"
  rm -rf "$SRC/proftpd-${PROFTPD_VERSION}"
  dir="$(unpack "proftpd-${PROFTPD_VERSION}.tar.gz")"
  pushd "$SRC/$dir" >/dev/null
  ./configure \
    --prefix="$PREFIX" \
    --sysconfdir="$PREFIX/etc" \
    --localstatedir="$PREFIX/var" \
    --enable-openssl \
    --disable-ident \
    --disable-ipv6
  make -j "$JOBS"
  make INSTALL_USER="$(id -un)" INSTALL_GROUP="$(id -gn)" install
  popd >/dev/null
fi

if [[ ! -f "$DATA/htdocs/phpmyadmin/index.php" ]]; then
  fetch "https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}/phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.xz" "phpmyadmin-${PHPMYADMIN_VERSION}.tar.xz"
  rm -rf "$SRC/phpmyadmin-unpack" "$DATA/htdocs/phpmyadmin"
  mkdir -p "$SRC/phpmyadmin-unpack"
  tar -xJf "$CACHE/phpmyadmin-${PHPMYADMIN_VERSION}.tar.xz" -C "$SRC/phpmyadmin-unpack"
  inner="$(find "$SRC/phpmyadmin-unpack" -mindepth 1 -maxdepth 1 -type d | head -1)"
  mv "$inner" "$DATA/htdocs/phpmyadmin"
  rm -rf "$DATA/htdocs/phpmyadmin/setup"
fi

ln -sfn "$PREFIX" "$DATA/stack"
cat > "$DATA/conf/stack-manifest.txt" << EOF
httpd ${HTTPD_VERSION}
php ${PHP_VERSION}
mariadb ${MARIADB_VERSION}
perl ${PERL_VERSION}
proftpd ${PROFTPD_VERSION}
phpmyadmin ${PHPMYADMIN_VERSION}
openssl ${OPENSSL_VERSION}
prefix ${PREFIX}
EOF
echo "Camp stack is installed at $PREFIX"
