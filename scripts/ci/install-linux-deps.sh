#!/usr/bin/env bash
set -euo pipefail
role=${1:?host or client}
source /etc/os-release
case "$role:$ID:$VERSION_ID" in
  host:rocky:9.7)
    test "$(id -u)" = 0
    # Freeze the Rocky minor release rather than following the moving 9 mirror.
    for pair in baseos:BaseOS appstream:AppStream crb:CRB extras:extras; do
      repo=${pair%%:*}; directory=${pair#*:}
      dnf config-manager --save --setopt="$repo.mirrorlist=" \
        --setopt="$repo.baseurl=https://dl.rockylinux.org/vault/rocky/9.7/$directory/\$basearch/os/"
    done
    dnf config-manager --set-enabled crb
    dnf install -y epel-release
    dnf install -y --setopt=install_weak_deps=False \
      autoconf automake clang cmake curl-minimal git libtool make nasm ninja-build patch \
      pkgconf-pkg-config ripgrep rpm-build cpio wget xz tar gzip python3 python3-jinja2 \
      gcc-toolset-14-gcc gcc-toolset-14-gcc-c++ \
      glib2-devel libcap-devel libdrm-devel libevdev-devel libva-devel \
      libX11-devel libxcb-devel libXcomposite-devel libXcursor-devel libXfixes-devel \
      libXi-devel libXinerama-devel libXrandr-devel libXtst-devel libxkbcommon-devel \
      mesa-libgbm-devel mesa-libGL-devel numactl-devel openssl-devel opus-devel \
      pam-devel pipewire-devel pulseaudio-libs-devel python3-devel systemd-devel \
      vulkan-loader-devel wayland-devel wayland-protocols-devel
    # The public CUDA 13 network index can publish repomd.xml while every
    # listed metadata object returns 404. Fall back to NVIDIA's pinned local
    # 13.0.2 repository, which carries its own package index.
    dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    if ! dnf makecache --disablerepo='*' --enablerepo=cuda-rhel9-x86_64; then
      echo "CUDA network repository metadata is unavailable; using the pinned 13.0.2 local repository" >&2
      dnf config-manager --set-disabled cuda-rhel9-x86_64
      mkdir -p "${PLANK_DEP_ROOT:?}"
      cuda_local="${PLANK_DEP_ROOT}/cuda-repo-rhel9-13-0-local-13.0.2_580.95.05-1.x86_64.rpm"
      curl --fail --location \
        https://developer.download.nvidia.com/compute/cuda/13.0.2/local_installers/cuda-repo-rhel9-13-0-local-13.0.2_580.95.05-1.x86_64.rpm \
        -o "$cuda_local"
      echo "a4d5056190d72ee8c68ad7cb86d286c8  ${cuda_local}" | md5sum -c -
      rpm --install "$cuda_local"
      shopt -s nullglob
      cuda_keys=(/var/cuda-repo-rhel9-13-0-local*/*.pub)
      (( ${#cuda_keys[@]} > 0 )) || {
        echo "CUDA local repository did not include a signing key" >&2
        exit 1
      }
      for cuda_key in "${cuda_keys[@]}"; do
        rpm --import "$cuda_key"
      done
    fi
    dnf install -y --setopt=install_weak_deps=False \
      cuda-compiler-13-0 cuda-cudart-devel-13-0 cuda-driver-devel-13-0 \
      cuda-nvml-devel-13-0 cuda-nvrtc-devel-13-0
    /usr/local/cuda/bin/nvcc --version
    python3 -c 'import jinja2' # Fail before the long FFmpeg bootstrap.
    rpm -qa | sort
    ;;
  client:ubuntu:26.04)
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential cmake curl git make nasm ninja-build openssl patch \
      pkg-config python3 python3-venv ripgrep xz-utils dpkg-dev \
      qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-wayland \
      libsdl3-dev libsdl3-ttf-dev libdecor-0-dev libdrm-dev libinput-dev \
      libopus-dev libplacebo-dev libssl-dev libudev-dev libva-dev libvdpau-dev \
      libwayland-dev libx11-dev zlib1g-dev
    test "$(qmake6 -query QT_VERSION)" = 6.10.2
    dpkg-query -W
    ;;
  client:ubuntu:24.04)
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential cmake curl git make nasm ninja-build openssl patch \
      pkg-config python3 python3-venv python3-pip ripgrep xz-utils dpkg-dev \
      file libdecor-0-dev libdrm-dev libegl1-mesa-dev libgl1-mesa-dev \
      libinput-dev libfreetype6-dev libopus-dev libplacebo-dev libssl-dev \
      libudev-dev libva-dev libvdpau-dev libwayland-dev libx11-dev \
      libxext-dev libxi-dev libxkbcommon-dev libasound2-dev zlib1g-dev \
      patchelf binutils
    dpkg-query -W
    ;;
  *) echo 'Unsupported CI product/OS tuple' >&2; exit 2 ;;
esac
