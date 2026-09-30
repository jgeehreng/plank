#!/usr/bin/env bash
# Build SDL3 3.4.2 and SDL3_ttf 3.2.2 from pinned sources for the Ubuntu 24.04
# client DEB. SDL3 is not available in Ubuntu 24.04 repositories; bundled libs
# carry a private RPATH and are excluded from system package dependencies.
set -euo pipefail
prefix="$PLANK_DEP_ROOT/client-sdl3/install"
downloads="$PLANK_DEP_ROOT/client-sdl3/downloads"
src="$PLANK_DEP_ROOT/client-sdl3/src"
jobs=${PLANK_BUILD_JOBS:-4}

if [[ -f "$prefix/lib/pkgconfig/sdl3.pc" && -f "$prefix/lib/pkgconfig/sdl3-ttf.pc" ]]; then
  exit 0
fi

mkdir -p "$prefix" "$downloads" "$src"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

fetch() {
  local url=$1 hash=$2 name=${1##*/}
  local archive="$downloads/$name"
  [[ -f $archive ]] || curl --fail --location --retry 3 --connect-timeout 30 \
    --max-time 900 --output "$archive" "$url"
  printf '%s  %s\n' "$hash" "$archive" | sha256sum --check --status
  tar -xf "$archive" -C "$src"
}

cmake_shared() {
  local name=$1; shift
  cmake -S "$src/$name" -B "$PLANK_DEP_ROOT/client-sdl3/build-$name" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$prefix" -DBUILD_SHARED_LIBS=ON "$@"
  cmake --build "$PLANK_DEP_ROOT/client-sdl3/build-$name" --parallel "$jobs"
  cmake --install "$PLANK_DEP_ROOT/client-sdl3/build-$name"
}

fetch https://libsdl.org/release/SDL3-3.4.2.tar.gz \
  ef39a2e3f9a8a78296c40da701967dd1b0d0d6e267e483863ce70f8a03b4050c
cmake_shared SDL3-3.4.2 -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_PIPEWIRE=ON

fetch https://download.savannah.gnu.org/releases/freetype/freetype-2.14.1.tar.xz \
  32427e8c471ac095853212a37aef816c60b42052d4d9e48230bab3bdf2936ccc
cmake_shared freetype-2.14.1 -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BZIP2=ON \
  -DFT_DISABLE_PNG=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_ZLIB=ON

fetch https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz \
  63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d
cmake_shared SDL3_ttf-3.2.2 -DSDLTTF_VENDORED=OFF -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_SAMPLES=OFF

pkg-config --modversion sdl3 sdl3-ttf
echo 'client_sdl3_gate=pass'
