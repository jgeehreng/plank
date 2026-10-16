#!/bin/bash
# Loopback macOS admission qualification. Builds an ephemeral probe and a
# test-signed bundle. Does not install a Host, reboot a machine, start a
# Broker, or write require_admission into host configuration.
set -euo pipefail
if [[ $# != 2 || $1 != /* || $2 != /* ]]; then
    echo "Usage: $0 /absolute/source-root /absolute/empty-output-directory" >&2
    exit 2
fi
source_root=$1
output=$2
if [[ $(uname -s) != Darwin || $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires the dedicated development Mac with macOS/SDK 27+." >&2
    exit 2
fi
mkdir -p "$output"
[[ -z $(ls -A "$output") ]] || { echo "Output directory must be empty." >&2; exit 2; }
openssl_prefix=${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}
xcrun clang -Wall -Wextra -Werror -DPLANK_ADMISSION_OPENSSL \
    -I"$source_root/apps/host/linux/src/auth" -I"$openssl_prefix/include" \
    "$source_root/tests/auth/mint-admission.c" \
    "$source_root/apps/host/linux/src/auth/plank_admission.c" \
    -L"$openssl_prefix/lib" -lcrypto -o "$output/mint-admission"
common=(-mmacosx-version-min=27.0 -fobjc-arc -Wall -Wextra -Werror
    -I"$source_root/apps/host/macos/auth" -I"$source_root/apps/host/macos/control"
    -I"$source_root/apps/host/linux/src/auth"
    -framework Foundation -framework Security -framework AppKit -framework CoreGraphics
    -framework SystemConfiguration -framework Network)
control_sources=("$source_root/apps/host/macos/control/http-request.m"
    "$source_root/apps/host/macos/control/server-information.m"
    "$source_root/apps/host/macos/control/fixed-capture.m"
    "$source_root/apps/host/macos/control/https-auth-server.m"
    "$source_root/apps/host/linux/src/auth/plank_admission.c"
    "$source_root/apps/host/macos/auth/authentication-session.m"
    "$source_root/apps/host/macos/auth/graphical-authority.m"
    "$source_root/probes/macos/https-auth.m")
xcrun clang "${common[@]}" -DPLANK_SYNTHETIC_AUTH_TEST "${control_sources[@]}" \
    -o "$output/https-auth-synthetic"
python3 "$source_root/tests/auth/macos-admission.py" --self-test
python3 "$source_root/tests/auth/macos-admission.py" \
    --server "$output/https-auth-synthetic" \
    --mint "$output/mint-admission" \
    --config "$source_root/probes/macos/https-cert.cnf"
