"""Exercise source gates without compiling a client or preparing dependencies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ClientSourceGateTests(unittest.TestCase):
    def test_svg_reader_is_an_explicit_build_and_runtime_dependency(self):
        for filename in ('scripts/ci/install-linux-deps.sh',
                         'docs/development/build/builder-vm-bootstrap.md',
                         'packaging/client/linux/deb/control.in',
                         'scripts/package/build-client-deb.sh'):
            with self.subTest(filename=filename):
                self.assertIn('qt6-svg-plugins', (ROOT / filename).read_text())
        self.assertIn('QT_INSTALL_PLUGINS)/imageformats/libqsvg.so',
                      (ROOT / 'scripts/ci/install-linux-deps.sh').read_text())

    def packet_size_gate(self, files):
        self.assertIsNotNone(shutil.which('rg'), 'source-gate tests require ripgrep')
        script = (ROOT / 'scripts/build/build-client-package-binaries.sh').read_text()
        gate = script.split('# Native KyProto owns media packetization.', 1)[1]
        gate = gate[gate.index('if rg -n '):].split('for required_mtu_token', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            for relative, content in files.items():
                path = Path(directory) / 'app' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            return subprocess.run(
                ['bash', '-c', 'source_dir="$1"\n' + gate, 'gate', directory],
                capture_output=True, text=True, check=False)

    def test_packet_size_prose_is_not_legacy_code(self):
        result = self.packet_size_gate({
            'res/changelog.md': 'Preserve valid packets during packet-size recovery.\n',
            'backend/current.cpp': 'int quicUdpPayloadMtu = 1200;\n',
        })
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retired_packet_size_controls_remain_rejected(self):
        for relative, content in (
            ('backend/cli.cpp', 'option("packet-size");\n'),
            ('backend/preferences.h', 'int packetSize MEMBER packetSize;\n'),
            ('gui/Settings.qml', 'text: "Physical path MTU"\n'),
            ('app.pro', 'DEFINES += SER_PACKETSIZE\n'),
        ):
            with self.subTest(relative=relative):
                result = self.packet_size_gate({relative: content})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('legacy packet-size configuration', result.stderr)

    def test_ubuntu_24_client_builds_its_private_runtime(self):
        deps = (ROOT / 'scripts/ci/install-linux-deps.sh').read_text()
        noble = deps.split('client:ubuntu:24.04)', 1)[1].split('*)', 1)[0]
        # Ubuntu 24.04's libplacebo 6.338 predates pl_gpu_limits.host_ptr_slow.
        install = noble.split('apt-get install', 1)[1].split('if dpkg-query', 1)[0]
        self.assertNotIn('libplacebo-dev', install)
        self.assertIn('libplacebo-dev is installed', noble)
        for package in ('meson', 'libshaderc-dev', 'libvulkan-dev', 'libpipewire-0.3-dev', 'patchelf'):
            self.assertIn(package, install)
        deb = (ROOT / 'scripts/package/build-client-deb.sh').read_text()
        self.assertIn('ubuntu-24.04) private_qt_runtime=1', deb)
        self.assertIn('control-ubuntu-24.04.in', deb)
        self.assertIn('libicui18n.so.73', deb)
        self.assertIn('client_qt_module_runpath_gate=pass', deb)
        script = (ROOT / 'scripts/package/build-ubuntu-24-client.sh').read_text()
        self.assertIn('VERSION_ID:-} != 24.04', script)
        self.assertIn('PLANK_CLIENT_DEB_DISTRO=ubuntu-24.04', script)
        self.assertIn('libplacebo_version=7.360.1', script)
        self.assertLess(script.index('libplacebo_commit='), script.index('meson setup'))
        self.assertLess(script.index('libicui18n.so.73'), script.index('qmake" -query QT_VERSION'))
        self.assertIn('pkg-config --exists sdl3 sdl3-ttf Qt6Gui libplacebo', script)
        binaries = (ROOT / 'scripts/build/build-client-package-binaries.sh').read_text()
        self.assertIn(
            'PKG_CONFIG_PATH="${ffmpeg_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"',
            binaries)
        self.assertLess(script.index('rm -rf "$client_build"'), script.index('build-client-package-binaries.sh'))
        # The client project builds the transport crate with --offline.
        self.assertLess(
            script.index('scripts/ci/dependencies/cargo.sh" linux-client'),
            script.index('build-client-package-binaries.sh'))


if __name__ == '__main__':
    unittest.main()
