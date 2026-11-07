import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("resources", ROOT / "scripts/validate-resources.py")
RESOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOURCES)


class PackagedResourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / "1132 Fixer_1132Fixer.bundle"

    def fixture(self, structured=False):
        directory = self.bundle / "Contents/Resources" if structured else self.bundle
        directory.mkdir(parents=True)
        (directory / "AppIcon.png").write_bytes((ROOT / "Sources/1132Fixer/Resources/AppIcon.png").read_bytes())
        (directory / "FIXER_BUG_REPORT_ENDPOINT").write_text("https://example.invalid/report\n")
        (directory / "FIXER_BUG_REPORT_TOKEN").write_text("fixture-write-only-token\n")
        return directory

    def test_flat_bundle_passes(self):
        self.fixture()
        RESOURCES.validate(self.bundle, True)

    def test_structured_bundle_passes(self):
        self.fixture(structured=True)
        RESOURCES.validate(self.bundle, True)

    def test_missing_empty_and_invalid_resources_fail(self):
        directory = self.fixture()
        for name in ["AppIcon.png", "FIXER_BUG_REPORT_ENDPOINT", "FIXER_BUG_REPORT_TOKEN"]:
            path = directory / name
            original = path.read_bytes()
            for value in [None, b"", b"\xffinvalid"]:
                with self.subTest(name=name, value=value):
                    if value is None:
                        path.unlink()
                    else:
                        path.write_bytes(value)
                    with self.assertRaises((ValueError, OSError, UnicodeError)):
                        RESOURCES.validate(self.bundle, True)
                    path.write_bytes(original)

    def test_invalid_endpoint_and_control_characters_fail_without_values_in_output(self):
        directory = self.fixture()
        for endpoint in ["http://example.invalid", "https:///missing-host", "https://user:pass@example.invalid"]:
            (directory / "FIXER_BUG_REPORT_ENDPOINT").write_text(endpoint)
            with self.assertRaises(ValueError):
                RESOURCES.validate(self.bundle, True)
        (directory / "FIXER_BUG_REPORT_ENDPOINT").write_text("https://example.invalid/report")
        secret = "DO-NOT-PRINT\r\nHeader: injected"
        (directory / "FIXER_BUG_REPORT_TOKEN").write_text(secret)
        result = subprocess.run([sys.executable, str(ROOT / "scripts/validate-resources.py"), str(self.bundle), "--require-bug-report"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("DO-NOT-PRINT", result.stdout + result.stderr)

    def test_ambiguous_layout_and_symlinked_resource_fail(self):
        directory = self.fixture()
        structured = self.bundle / "Contents/Resources"
        structured.mkdir(parents=True)
        (structured / "AppIcon.png").write_bytes((directory / "AppIcon.png").read_bytes())
        with self.assertRaises(ValueError):
            RESOURCES.validate(self.bundle, True)
        (structured / "AppIcon.png").unlink()
        path = directory / "FIXER_BUG_REPORT_TOKEN"
        path.unlink()
        path.symlink_to(directory / "FIXER_BUG_REPORT_ENDPOINT")
        with self.assertRaises(ValueError):
            RESOURCES.validate(self.bundle, True)

    def test_adhoc_fixture_does_not_require_distribution_credentials(self):
        directory = self.fixture()
        (directory / "FIXER_BUG_REPORT_TOKEN").unlink()
        RESOURCES.validate(self.bundle, False)
        with self.assertRaises(ValueError):
            RESOURCES.validate(self.bundle, True)
