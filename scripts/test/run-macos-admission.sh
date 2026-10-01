#!/bin/bash
# Phase 0 loopback gate for macOS /plank/auth/start. Synthetic account only.
set -euo pipefail
if [[ $# != 1 || $1 != /* ]]; then
    echo "Usage: $0 /absolute/source-root" >&2
    exit 2
fi
source_root=$1
output=$(mktemp -d)
openssl_prefix=${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}
clang -Wall -Wextra -Werror -DPLANK_ADMISSION_OPENSSL \
    -I"$source_root/apps/host/linux/src/auth" -I"$openssl_prefix/include" \
    "$source_root/tests/auth/mint-admission.c" "$source_root/apps/host/linux/src/auth/plank_admission.c" \
    -L"$openssl_prefix/lib" -lcrypto -o "$output/mint-admission"
common=(-mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror
    -I"$source_root/apps/host/macos/auth" -I"$source_root/apps/host/macos/control"
    -I"$source_root/apps/host/linux/src/auth"
    -framework Foundation -framework Security -framework AppKit -framework CoreGraphics
    -framework SystemConfiguration -framework Network)
xcrun clang "${common[@]}" -DPLANK_SYNTHETIC_AUTH_TEST \
    "$source_root/apps/host/macos/control/http-request.m" \
    "$source_root/apps/host/macos/control/server-information.m" \
    "$source_root/apps/host/macos/control/fixed-capture.m" \
    "$source_root/apps/host/macos/control/https-auth-server.m" \
    "$source_root/apps/host/linux/src/auth/plank_admission.c" \
    "$source_root/apps/host/macos/auth/authentication-session.m" \
    "$source_root/apps/host/macos/auth/graphical-authority.m" \
    "$source_root/probes/macos/https-auth.m" -o "$output/https-auth-synthetic"
python3 "$source_root/tests/auth/macos-admission.py" "$source_root" "$output/https-auth-synthetic" "$output/mint-admission"
rm -rf "$output"
