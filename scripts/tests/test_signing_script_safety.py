"""Signing-script safety checks that run without macOS, a keychain or credentials.

F-031: the keychain search-list parser keeps exact quoted paths and refuses unknown
shapes before any mutation. `security` is a shell-function stub; no real keychain or
search list is read or changed.
F-037: CI packaging steps that carry credentials pin APPLE_DEVELOPER_FILE=/dev/null.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/build-universal-dmg.sh").read_text()
BASH = os.environ.get("FIXTURE_BASH", "/bin/bash")


def between(start, end):
    begin = SCRIPT.index(start)
    finish = SCRIPT.index(end, begin)
    return SCRIPT[begin:finish]


PARSER = between("# BEGIN parse_keychain_list", "# END parse_keychain_list")
CAPTURE = between("  # Capture and validate the user search list", '  echo "==> Importing signing certificate')


class KeychainListParserTests(unittest.TestCase):
    def parse(self, listing):
        script = PARSER + '\nparse_keychain_list\n'
        return subprocess.run([BASH, "-c", script], input=listing, capture_output=True, text=True)

    def test_indentation_outside_quotes_is_trimmed_and_inner_spaces_are_kept(self):
        listing = (
            '    "/Users/a/Library/Keychains/login.keychain-db"\n'
            '\t"/Users/a/Library/Keychains/ leading and inner .keychain-db"  \n'
            '\n'
            '    "/Library/Keychains/System.keychain"'
        )
        result = self.parse(listing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("\n")[:-1], [
            "/Users/a/Library/Keychains/login.keychain-db",
            "/Users/a/Library/Keychains/ leading and inner .keychain-db",
            "/Library/Keychains/System.keychain",
        ])

    def test_unrecognized_shapes_fail(self):
        for listing in [
            '    /Users/a/login.keychain-db\n',
            '    "relative/login.keychain-db"\n',
            '    "/a" "/b"\n',
            '    "/a" trailing\n',
            '    "/a\n',
            'error: something went wrong\n',
        ]:
            with self.subTest(listing=listing):
                self.assertNotEqual(self.parse(listing).returncode, 0)


class KeychainCaptureTests(unittest.TestCase):
    def run_capture(self, listing, list_status=0):
        directory = tempfile.mkdtemp()
        listing_file = Path(directory) / "listing"
        listing_file.write_text(listing)
        mutations = Path(directory) / "mutations"
        script = f"""
set -euo pipefail
{PARSER}
security() {{
  if [ "$1" = list-keychains ] && [ "$#" -eq 3 ]; then cat {listing_file}; return {list_status}; fi
  echo "$*" >> {mutations}
}}
KEYCHAIN_PATH=/tmp/build/build-signing.keychain-db
ORIGINAL_KEYCHAINS=()
{CAPTURE}
security list-keychains -d user -s "$KEYCHAIN_PATH" "${{ORIGINAL_KEYCHAINS[@]}}"
for k in "${{ORIGINAL_KEYCHAINS[@]}}"; do printf '[%s]\\n' "$k"; done
"""
        result = subprocess.run([BASH, "-c", script], capture_output=True, text=True)
        changed = mutations.read_text() if mutations.exists() else ""
        return result, changed

    def test_exact_list_is_captured_before_any_mutation(self):
        result, changed = self.run_capture(
            '    "/Users/a/Library/Keychains/login.keychain-db"\n'
            '    "/tmp/build/build-signing.keychain-db"\n'
            '    "/Users/a/Library/Keychains/my keys.keychain-db"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "[/Users/a/Library/Keychains/login.keychain-db]",
            "[/Users/a/Library/Keychains/my keys.keychain-db]",
        ])

    def test_invalid_empty_or_unreadable_lists_abort_before_mutation(self):
        for listing, status in [("   garbage\n", 0), ("", 0), ("\n  \n", 0),
                                ('    "/tmp/build/build-signing.keychain-db"\n', 0),
                                ('    "/Users/a/login.keychain-db"\n', 1)]:
            with self.subTest(listing=listing, status=status):
                result, changed = self.run_capture(listing, status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(changed, "")
                self.assertIn("refusing", result.stderr)

    def test_restore_on_exit_uses_the_captured_list(self):
        cleanup = re.search(r'security list-keychains -d user -s "\$\{ORIGINAL_KEYCHAINS\[@\]\}"', SCRIPT)
        self.assertIsNotNone(cleanup)
        self.assertIn("trap on_build_exit EXIT", SCRIPT)
        self.assertLess(SCRIPT.index("# Capture and validate the user search list"),
                        SCRIPT.index('security create-keychain -p'))


class CredentialStepConfigurationTests(unittest.TestCase):
    def test_credential_bearing_packaging_steps_ignore_repository_settings(self):
        for workflow in ["build-dmg.yml", "release.yml"]:
            text = (ROOT / ".github/workflows" / workflow).read_text()
            steps = re.split(r"\n      - ", text)
            credential_steps = [s for s in steps if "APPLE_CERTIFICATE:" in s and "build-universal-dmg.sh" in s]
            with self.subTest(workflow=workflow):
                self.assertTrue(credential_steps, "no credential-bearing packaging step found")
                for step in credential_steps:
                    self.assertRegex(step, r"APPLE_DEVELOPER_FILE:\s*/dev/null")

    def test_tracked_settings_file_is_refused(self):
        self.assertIn("ls-files --error-unmatch -- apple-developer.txt", SCRIPT)
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "apple-developer.txt"],
                                 capture_output=True, text=True)
        self.assertEqual(tracked.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
