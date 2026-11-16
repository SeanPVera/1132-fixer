import importlib.util
from pathlib import Path
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
        return directory

    def test_flat_bundle_passes(self):
        self.fixture()
        RESOURCES.validate(self.bundle)

    def test_structured_bundle_passes(self):
        self.fixture(structured=True)
        RESOURCES.validate(self.bundle)

    def test_missing_empty_and_invalid_icon_fail(self):
        path = self.fixture() / "AppIcon.png"
        original = path.read_bytes()
        for value in [None, b"", b"\xffinvalid"]:
            with self.subTest(value=value):
                if value is None:
                    path.unlink()
                else:
                    path.write_bytes(value)
                with self.assertRaises((ValueError, OSError)):
                    RESOURCES.validate(self.bundle)
                path.write_bytes(original)

    def test_ambiguous_layout_and_symlinked_icon_fail(self):
        directory = self.fixture()
        structured = self.bundle / "Contents/Resources"
        structured.mkdir(parents=True)
        (structured / "AppIcon.png").write_bytes((directory / "AppIcon.png").read_bytes())
        with self.assertRaises(ValueError):
            RESOURCES.validate(self.bundle)
        (structured / "AppIcon.png").unlink()
        icon = directory / "AppIcon.png"
        real = directory / "real.png"
        icon.rename(real)
        icon.symlink_to(real)
        with self.assertRaises(ValueError):
            RESOURCES.validate(self.bundle)


if __name__ == "__main__":
    unittest.main()
