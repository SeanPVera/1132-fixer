"""Run the rendered reset script against disposable home directories.

The preferences-domain call is rendered as a no-op (`deletePreferencesDomain: false`),
so nothing here talks to cfprefsd or a real Zoom install. These checks do not establish
Darwin filesystem flags or sandbox behavior.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from swift_fragments import literal_after, raw_literal, render

BASH = os.environ.get("FIXTURE_BASH", "/bin/bash")
STATE_PATHS = [
    "Library/Application Support/zoom.us",
    "Library/Caches/us.zoom.xos",
    "Library/Preferences/us.zoom.xos.plist",
    "Library/Saved Application State/us.zoom.xos.savedState",
]
LOG_FUNCTION = raw_literal("zoomLogCandidatesFunction")


def quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def reset_script(home):
    template = literal_after("static func makeResetZoomDataCommand(")
    values = {
        "home": quote(home),
        "zoomLogCandidatesFunction": LOG_FUNCTION,
        "ZoomStateScope.logsRelativeDirectory": "Library/Logs",
        "preferencesStep": ": # preferences-domain deletion disabled for this fixture",
    }
    for index, path in enumerate(STATE_PATHS):
        values[f"ZoomStateScope.statePaths[{index}]"] = path
    return render(template, **values)


class ResetFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(os.path.realpath(self.temp.name)) / "home"
        for parent in ["Library/Application Support", "Library/Caches", "Library/Preferences",
                       "Library/Logs", "Library/Saved Application State"]:
            (self.home / parent).mkdir(parents=True)
        (self.home / STATE_PATHS[0]).mkdir()
        (self.home / STATE_PATHS[0] / "session.db").write_text("session")
        (self.home / STATE_PATHS[1]).mkdir()
        (self.home / STATE_PATHS[1] / "cache.bin").write_text("cache")
        (self.home / STATE_PATHS[2]).write_text("prefs")
        (self.home / STATE_PATHS[3]).mkdir()
        self.logs = self.home / "Library/Logs"
        (self.logs / "zoom.us.log").write_text("current log")
        (self.logs / "zoom.us.log.1").write_text("rotated log")

    def run_script(self, script):
        return subprocess.run([BASH, "-c", script], capture_output=True, text=True, timeout=60)

    def reset(self):
        return self.run_script(reset_script(str(self.home)))

    # F-027: exact log naming contract.
    def test_near_match_log_names_survive_and_rotations_are_removed(self):
        near = ["zoom.us.logbook-UNRELATED.txt", "zoom.us.log.old", "zoom.us.log.1.txt", "zoom.us.log."]
        for name in near:
            (self.logs / name).write_text("unrelated")
        result = self.reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.logs / "zoom.us.log").exists())
        self.assertFalse((self.logs / "zoom.us.log.1").exists())
        for name in near:
            self.assertTrue((self.logs / name).exists(), name)
        for path in STATE_PATHS:
            self.assertFalse((self.home / path).exists(), path)

    # F-026: a directory with a log-like name no longer turns into a partial reset.
    def test_log_named_directory_is_left_alone_without_failing_the_reset(self):
        (self.logs / "zoom.us.log.dir").mkdir()
        (self.logs / "zoom.us.log.2").mkdir()
        (self.logs / "zoom.us").mkdir()
        result = self.reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.logs / "zoom.us.log.dir").is_dir())
        self.assertTrue((self.logs / "zoom.us.log.2").is_dir())
        self.assertIn("not a regular log file", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root bypasses permission bits")
    def test_unremovable_state_is_refused_before_anything_is_deleted(self):
        locked = self.home / STATE_PATHS[1] / "locked"
        locked.mkdir()
        (locked / "inner").write_text("x")
        locked.chmod(0o500)
        self.addCleanup(locked.chmod, 0o700)
        result = self.reset()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Nothing was deleted", result.stderr)
        for path in STATE_PATHS:
            self.assertTrue((self.home / path).exists(), path)
        self.assertTrue((self.logs / "zoom.us.log").exists())

    @unittest.skipIf(os.geteuid() == 0, "root bypasses permission bits")
    def test_unwritable_log_directory_is_refused_before_state_deletion(self):
        self.logs.chmod(0o500)
        self.addCleanup(self.logs.chmod, 0o700)
        result = self.reset()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Nothing was deleted", result.stderr)
        self.assertTrue((self.home / STATE_PATHS[0] / "session.db").exists())

    def test_symlinked_log_is_removed_without_touching_its_target(self):
        outside = Path(self.temp.name) / "outside.log"
        outside.write_text("keep me")
        (self.logs / "zoom.us.log.3").symlink_to(outside)
        result = self.reset()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.logs / "zoom.us.log.3").is_symlink())
        self.assertEqual(outside.read_text(), "keep me")

    def test_rendered_scripts_have_no_unexpanded_interpolation(self):
        script = reset_script(str(self.home))
        self.assertNotIn("\\(Zoom", script)
        self.assertIn("__1132_zoom_log_candidates", script)


if __name__ == "__main__":
    unittest.main()
