#!/usr/bin/env bash
set -euo pipefail
# Temporary CI-branch diagnostics: surface the end of a failed build as an
# annotation, because job logs are not readable from the review session.
plank_diag_log="${RUNNER_TEMP:-/tmp}/plank-build-diagnostics.log"
exec > >(tee "$plank_diag_log") 2>&1
trap 'rc=$?; if [ "$rc" -ne 0 ]; then sleep 2; enc() { python3 -c "import sys; print(\"%0A\".join(l.rstrip(\"\r\n\")[:220].replace(\"%\",\"%25\") for l in sys.stdin))"; }; printf "::error title=build errors::%s\n" "$(grep -nE "error:|Error |FAIL|Traceback|Assert|undefined|cannot find|not found|No such|\*\*\*" "$plank_diag_log" | grep -v thiserror | tail -n 40 | enc)"; printf "::error title=build tail::%s\n" "$(tail -n 30 "$plank_diag_log" | enc)"; fi' EXIT
role=${1:?product role required}
export CARGO_HOME="$PLANK_CARGO_ROOT" RUSTUP_HOME="$PLANK_RUSTUP_ROOT"
export PATH="$CARGO_HOME/bin:$PATH"
export CARGO_NET_OFFLINE=true
python3 "$PLANK_SOURCE_ROOT/tests/network/test_datagram_sender.py"
case $role in
  linux-host)
    bash "$PLANK_SOURCE_ROOT/tests/protocol/test-occupancy-indicator.sh"
    export PLANK_HOST_FFMPEG_BUILD="$PLANK_SOURCE_ROOT/apps/host/linux/third-party/build-deps/build"
    export PLANK_HOST_FFMPEG_ROOT="$PLANK_DEP_ROOT/host-ffmpeg"
    export PLANK_BOOST_SOURCE_DIR="$PLANK_DEP_ROOT/boost-1.89.0"
    mkdir -p "$PLANK_SOURCE_ROOT/apps/host/linux/cmake-build-ffmpeg-x264rgb-install" "$PLANK_WORK_ROOT/tmp"
    ln -s "$PLANK_HOST_FFMPEG_ROOT" "$PLANK_SOURCE_ROOT/apps/host/linux/cmake-build-ffmpeg-x264rgb-install/ffmpeg"
    TMPDIR="$PLANK_WORK_ROOT/tmp" bash "$PLANK_SOURCE_ROOT/scripts/package/build-host-rpm.sh" "$PLANK_WORK_ROOT/host-build" "$PLANK_WORK_ROOT/host-package"
    bash "$PLANK_SOURCE_ROOT/scripts/ci/test-linux-host-input.sh" "$PLANK_WORK_ROOT/host-build"
    ;;
  linux-client)
    export PLANK_CLIENT_SDL_WORK="$PLANK_DEP_ROOT/client-sdl"
    bash "$PLANK_SOURCE_ROOT/scripts/build/build-client-package-binaries.sh" \
      "$PLANK_SOURCE_ROOT/apps/client" "$PLANK_DEP_ROOT/client-ffmpeg" "$PLANK_WORK_ROOT/client-build"
    bash "$PLANK_SOURCE_ROOT/scripts/package/build-client-deb.sh" \
      "$PLANK_WORK_ROOT/client-build/app/plank-client" "$PLANK_DEP_ROOT/client-ffmpeg" \
      "$PLANK_WORK_ROOT/client-package" "$PLANK_SOURCE_ROOT/apps/client"
    ;;
  macos-host)
    source "$PLANK_SOURCE_ROOT/scripts/package/package-version.sh"
    plank_load_package_version "$PLANK_SOURCE_ROOT"
    # Isolated installer filesystem fixture only; never install the product or
    # start its services on a builder. This also checks administrator log access.
    sudo -n /bin/bash "$PLANK_SOURCE_ROOT/tests/packaging/macos-pkg-scripts.sh" --filesystem
    PLANK_MACOS_SOURCE_FIRST=1 bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-transport.sh" "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/transport"
    if [[ ${PLANK_CI_SIGNED:-false} = true ]]; then
      bash "$PLANK_SOURCE_ROOT/scripts/package/build-macos-host-pkg.sh" "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/host-package" "$PLANK_WORK_ROOT/transport/release/libplank_transport.a"
    else
      (
      # Prove app assembly does not inherit an operator's private umask.
      umask 077
      PLANK_MACOS_HOST_VERSION="$PLANK_PACKAGE_VERSION" bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-host.sh" \
        "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/host-build" "$PLANK_WORK_ROOT/transport/release/libplank_transport.a"
      )
    fi
    ;;
  macos-client)
    bash "$PLANK_SOURCE_ROOT/scripts/test/build-macos-configuration.sh" "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-config-tests"
    export PLANK_MAC_CLIENT_DEPS="$PLANK_DEP_ROOT/macos-client" PLANK_QT_ROOT="$PLANK_DEP_ROOT/qt/6.10.2/macos"
    if [[ ${PLANK_CI_SIGNED:-false} = true ]]; then
      bash "$PLANK_SOURCE_ROOT/scripts/package/build-macos-client-pkg.sh" "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-package"
    else
      bash "$PLANK_SOURCE_ROOT/scripts/build/build-macos-client.sh" "$PLANK_SOURCE_ROOT" "$PLANK_WORK_ROOT/client-build"
      # CI-branch only: an ad-hoc-signed test app for hands-on testing. Not a
      # distributable package; no Developer ID, notarization or installer.
      test_root="$PLANK_ARTIFACT_ROOT/test-client"
      test_app="$test_root/PLANK Client Broker Test.app"
      mkdir -p "$test_root"
      ditto "$PLANK_WORK_ROOT/client-build/app/plank-client.app" "$test_app"
      "$PLANK_QT_ROOT/bin/macdeployqt" "$test_app" "-qmldir=$PLANK_SOURCE_ROOT/apps/client/app/gui" -always-overwrite
      codesign --force --deep --sign - "$test_app"
      codesign --verify --deep --strict "$test_app"
      otool -L "$test_app/Contents/MacOS/plank-client" | tail -n +2 | grep -E '^[[:space:]]+/(Users|opt|usr/local)/' && echo "::warning::test app links outside its bundle"
      (cd "$test_root" && ditto -c -k --keepParent "PLANK Client Broker Test.app" plank-client-broker-test.zip && rm -rf "PLANK Client Broker Test.app")
    fi
    ;;
  *) exit 2 ;;
esac
test -z "$(git -C "$PLANK_SOURCE_ROOT" status --porcelain)"
echo 'hosted_build_gate=pass hardware_acceptance=not-performed'
