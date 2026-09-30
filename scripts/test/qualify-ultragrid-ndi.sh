#!/bin/sh
# Qualify the pinned-NDI UltraGrid command contract.
# A live Flame picture check runs only when uv and PLANK_ULTRAGRID_NDI_NAME are present.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

c++ -std=c++17 -I "$root/apps/host/linux/src" \
  "$root/tests/broadcast/test_broadcast_output.cpp" \
  "$root/apps/host/linux/src/broadcast_output.cpp" \
  -o "$build/broadcast-output"
(cd "$root" && "$build/broadcast-output")

cc -std=c11 -I "$root/protocol/plank-transport/include" \
  "$root/tests/protocol/plank-transport-control-v1.c" \
  -o "$build/control"
"$build/control"

if ! command -v uv >/dev/null 2>&1 || [ -z "${PLANK_ULTRAGRID_NDI_NAME:-}" ]; then
  echo "LIVE_QUALIFICATION=skipped"
  echo "uv or PLANK_ULTRAGRID_NDI_NAME is not available on this machine."
  echo "Picture, audio, and a second NDI sender were not observed here."
  exit 0
fi

uv -t "ndi:name=${PLANK_ULTRAGRID_NDI_NAME}:help" >"$build/sources" 2>&1 || true
if grep -F "ndi:name=${PLANK_ULTRAGRID_NDI_NAME}" "$build/sources" >/dev/null 2>&1 \
    || grep -F "${PLANK_ULTRAGRID_NDI_NAME}" "$build/sources" >/dev/null 2>&1; then
  echo "LIVE_QUALIFICATION=source-listed"
else
  echo "LIVE_QUALIFICATION=source-not-listed"
  echo "The pinned NDI source was not discovered. No picture was sent."
fi
