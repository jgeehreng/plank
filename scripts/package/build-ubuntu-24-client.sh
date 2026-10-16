#!/usr/bin/env bash
# Build a Ubuntu 24.04 Client DEB with pinned Qt 6.10.2, SDL3 3.4.2, and
# FFmpeg 9.0.1. Intended for an Ubuntu 24.04 x86_64 container or VM — not a
# live ComfyUI/GPU runtime and not a Flame host.

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
dep_root=${PLANK_DEP_ROOT:-${repo_dir}/build/ubuntu-24-client-deps}
work_root=${PLANK_WORK_ROOT:-${repo_dir}/build/ubuntu-24-client-work}
jobs=${PLANK_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
qt_version=6.10.2
sdl3_version=3.4.2
sdl3_sha256=ef39a2e3f9a8a78296c40da701967dd1b0d0d6e267e483863ce70f8a03b4050c
sdl3_ttf_version=3.2.2
sdl3_ttf_sha256=63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d

if [[ ! -f /etc/os-release ]]; then
  echo "Ubuntu 24.04 builder must run on Linux" >&2
  exit 2
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  echo "Ubuntu 24.04 builder must run on Ubuntu 24.04, found ${ID:-unknown} ${VERSION_ID:-unknown}" >&2
  exit 2
fi
if [[ $(uname -m) != x86_64 ]]; then
  echo "Ubuntu 24.04 client DEB is amd64-only" >&2
  exit 2
fi

mkdir -p "$dep_root" "$work_root"
export PLANK_DEP_ROOT="$dep_root" PLANK_WORK_ROOT="$work_root"
export PLANK_SOURCE_ROOT="${PLANK_SOURCE_ROOT:-$repo_dir}"
export PLANK_CARGO_ROOT="${PLANK_CARGO_ROOT:-$dep_root/cargo}"
export PLANK_RUSTUP_ROOT="${PLANK_RUSTUP_ROOT:-$dep_root/rustup-1.89.0}"
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"

bash "$repo_dir/scripts/ci/install-linux-deps.sh" client

if [[ ! -x $dep_root/qt/$qt_version/gcc_64/bin/qmake ]]; then
  python3 -m venv "$dep_root/aqt"
  "$dep_root/aqt/bin/pip" install aqtinstall==3.3.0
  "$dep_root/aqt/bin/aqt" install-qt linux desktop "$qt_version" linux_gcc_64 \
    --outputdir "$dep_root/qt" \
    --archives qtbase qtdeclarative qtsvg qttools qtshadertools
fi
test "$("$dep_root/qt/$qt_version/gcc_64/bin/qmake" -query QT_VERSION)" = "$qt_version"

fetch_and_check() {
  local url=$1 archive=$2 sha256=$3
  if [[ ! -f $archive ]]; then
    curl --fail --location --output "$archive" "$url"
  fi
  printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status
}

cmake_shared() {
  local name=$1
  shift
  local source=$dep_root/src/$name
  local build=$work_root/$name
  cmake -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$dep_root/prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$dep_root/prefix" \
    "$@"
  cmake --build "$build" --parallel "$jobs"
  cmake --install "$build"
}

mkdir -p "$dep_root/src" "$dep_root/prefix"
if [[ ! -f $dep_root/prefix/lib/libSDL3.so ]]; then
  fetch_and_check \
    "https://libsdl.org/release/SDL3-${sdl3_version}.tar.gz" \
    "$dep_root/src/SDL3-${sdl3_version}.tar.gz" \
    "$sdl3_sha256"
  tar -xzf "$dep_root/src/SDL3-${sdl3_version}.tar.gz" -C "$dep_root/src"
  cmake_shared "SDL3-${sdl3_version}" -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF
fi
if [[ ! -f $dep_root/prefix/lib/libSDL3_ttf.so ]]; then
  fetch_and_check \
    "https://github.com/libsdl-org/SDL_ttf/releases/download/release-${sdl3_ttf_version}/SDL3_ttf-${sdl3_ttf_version}.tar.gz" \
    "$dep_root/src/SDL3_ttf-${sdl3_ttf_version}.tar.gz" \
    "$sdl3_ttf_sha256"
  tar -xzf "$dep_root/src/SDL3_ttf-${sdl3_ttf_version}.tar.gz" -C "$dep_root/src"
  cmake_shared "SDL3_ttf-${sdl3_ttf_version}" -DSDLTTF_VENDORED=OFF \
    -DSDLTTF_HARFBUZZ=OFF -DSDLTTF_SAMPLES=OFF
fi

export PKG_CONFIG_PATH="$dep_root/prefix/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$dep_root/qt/$qt_version/gcc_64/bin:$dep_root/prefix/bin:$PATH"
pkg-config --exists sdl3 sdl3-ttf
test "$(pkg-config --modversion sdl3)" = "$sdl3_version"

if [[ ! -x $CARGO_HOME/bin/rustc ]]; then
  installer="$dep_root/rustup-bootstrap"
  mkdir -p "$installer"
  curl --fail --location \
    "https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init" \
    -o "$installer/rustup-init"
  curl --fail --location \
    "https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init.sha256" \
    -o "$installer/rustup-init.sha256"
  (cd "$installer" && sha256sum -c rustup-init.sha256)
  chmod 0755 "$installer/rustup-init"
  RUSTUP_INIT_SKIP_PATH_CHECK=yes "$installer/rustup-init" -y --no-modify-path \
    --profile minimal --default-toolchain 1.89.0
fi
if [[ ! -f $dep_root/client-ffmpeg/install/lib/libavcodec.so ]]; then
  bash "$repo_dir/scripts/build/build-client-ffmpeg.sh" \
    "$work_root/ffmpeg-stage" "$dep_root/client-ffmpeg"
fi

ffmpeg_work=${PLANK_CLIENT_FFMPEG_WORK:-$dep_root/client-ffmpeg}
client_build=$work_root/package-client
bash "$repo_dir/scripts/build/build-client-package-binaries.sh" \
  "$repo_dir/apps/client" "$ffmpeg_work" "$client_build"

moonlight_binary=$(find "$client_build" -type f -name moonlight -o -name plank-client | head -n 1)
[[ -n $moonlight_binary && -x $moonlight_binary ]] || {
  echo "built client binary was not found in ${client_build}" >&2
  exit 1
}

export PLANK_CLIENT_DEB_DISTRO=ubuntu-24.04
export PLANK_CLIENT_QT_RUNTIME="$dep_root/qt/$qt_version/gcc_64"
export PLANK_CLIENT_PRIVATE_LIB_DIR="$dep_root/prefix/lib"
export PLANK_BUILD_BRANCH="${PLANK_BUILD_BRANCH:-main}"
bash "$repo_dir/scripts/package/build-client-deb.sh" \
  "$moonlight_binary" "$ffmpeg_work"
