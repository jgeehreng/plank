#!/bin/bash
# Compile and run the PLAD v1 admission codec against OpenSSL and, on macOS,
# Security.framework. This does not build the Host or contact a broker.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
openssl_prefix=${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}
out=$(mktemp -d)
clang -Wall -Wextra -Werror -DPLANK_ADMISSION_OPENSSL \
    -I"$root/apps/host/linux/src/auth" -I"$openssl_prefix/include" \
    "$root/tests/auth/test-admission.c" "$root/apps/host/linux/src/auth/plank_admission.c" \
    -L"$openssl_prefix/lib" -lcrypto -pthread -o "$out/admission-openssl"
"$out/admission-openssl"
if [[ $(uname -s) == Darwin ]]; then
    clang -Wall -Wextra -Werror \
        -I"$root/apps/host/linux/src/auth" -I"$openssl_prefix/include" \
        "$root/tests/auth/test-admission.c" "$root/apps/host/linux/src/auth/plank_admission.c" \
        -L"$openssl_prefix/lib" -lcrypto -framework Security -framework CoreFoundation -pthread \
        -o "$out/admission-security"
    "$out/admission-security"
fi
rm -rf "$out"
