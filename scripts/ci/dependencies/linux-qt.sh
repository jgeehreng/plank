#!/usr/bin/env bash
# Install Qt 6.10.2 for the Ubuntu 24.04 Linux client builder via aqtinstall.
# Qt is bundled into the DEB; the distro does not provide Qt 6.10.2 on 24.04.
set -euo pipefail
qt_root="$PLANK_DEP_ROOT/qt/6.10.2/gcc_64"
if [[ ! -x "$qt_root/bin/qmake6" || ! -f "$qt_root/plugins/platforms/libqwayland-generic.so" ]]; then
  python3 -m venv "$PLANK_DEP_ROOT/aqt"
  "$PLANK_DEP_ROOT/aqt/bin/pip" install aqtinstall==3.3.0
  "$PLANK_DEP_ROOT/aqt/bin/aqt" install-qt linux desktop 6.10.2 linux_gcc_64 \
    --outputdir "$PLANK_DEP_ROOT/qt" \
    --archives qtbase qtdeclarative qtsvg qttools qtshadertools qtwayland qtimageformats
fi
# The aqtinstall Qt 6.10.2 Linux binaries bundle ICU 73 in the Qt lib
# directory.  Ubuntu 24.04 ships ICU 74, so we must point qmake6 at its
# own bundled ICU before running it here and during the build step.
export LD_LIBRARY_PATH="$qt_root/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
test "$("$qt_root/bin/qmake6" -query QT_VERSION)" = '6.10.2'
test -f "$qt_root/plugins/platforms/libqwayland-generic.so"
