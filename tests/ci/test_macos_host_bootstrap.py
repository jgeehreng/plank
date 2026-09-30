"""The hosted Mac host build must see the shared admission codec."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MacosHostBootstrapTests(unittest.TestCase):
    def test_admission_codec_is_checked_out_without_linux_dependencies(self):
        source = (ROOT / 'scripts/ci/bootstrap.sh').read_text()
        self.assertIn('submodule update --init apps/host/linux', source)
        self.assertNotIn('submodule update --init --recursive apps/host/linux', source)
        self.assertIn('submodule.apps/host/linux.ignore dirty', source)
        self.assertIn('apps/host/linux/src/auth/plank_admission.c', source)


if __name__ == '__main__':
    unittest.main()
