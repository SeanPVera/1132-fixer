"""Run the rendered backup and reset scripts against disposable home directories.

The preferences-domain call is rendered as a no-op (`deletePreferencesDomain: false`),
so nothing here talks to cfprefsd or a real Zoom install. These checks do not establish
Darwin filesystem flags or sandbox behavior.
"""
import hashlib
import os
import shlex
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from swift_fragments import SOURCE, literal_after, raw_literal, render

BASH = os.environ.get("FIXTURE_BASH", "/bin/bash")
STATE_PATHS = [
    "Library/Application Support/zoom.us",
    "Library/Caches/us.zoom.xos",
    "Library/Preferences/us.zoom.xos.plist",
    "Library/Saved Application State/us.zoom.xos.savedState",
]
BACKUP_ROOT = "Library/Application Support/1132Fixer/Backups"
LOG_FUNCTION = raw_literal("zoomLogCandidatesFunction")
STAGING_FUNCTION = raw_literal("abandonedStagingCleanupFunction")


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
        values[f"ZoomStateScope.backedUpPaths[{index}]"] = path
    return render(template, **values)


def backup_script(home, count=5, cap_kb=2_097_152):
    template = literal_after("static func makeBackupZoomDataCommand(")
    values = {
        "home": quote(home),
        "ZoomStateScope.backupRelativeRoot": BACKUP_ROOT,
        "abandonedStagingCleanupFunction": STAGING_FUNCTION,
        "zoomLogCandidatesFunction": LOG_FUNCTION,
        'ZoomStateScope.backedUpPaths.map { "\\"$home_physical/\\($0)\\"" }.joined(separator: " ")':
            " ".join(f'"$home_physical/{path}"' for path in STATE_PATHS),
        "ZoomStateScope.logsRelativeDirectory": "Library/Logs",
        "ZoomStateScope.backupLogsSubdirectory": "Logs",
        "timestamp": "2026-01-01T00-00-00Z",
        "firstStaleEntry - 1": count,
        "maximumKilobytes": cap_kb,
    }
    return render(template, **values)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ResetBackupFixtureTests(unittest.TestCase):
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

    def backup(self, **kwargs):
        return self.run_script(backup_script(str(self.home), **kwargs))

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

    # F-026/F-027: everything the reset deletes is in the verified backup first.
    def test_backup_covers_every_reset_target_and_recovers_by_hash(self):
        before = {
            "Library/Application Support/zoom.us/session.db": digest(self.home / STATE_PATHS[0] / "session.db"),
            "Library/Preferences/us.zoom.xos.plist": digest(self.home / STATE_PATHS[2]),
            "Library/Logs/zoom.us.log": digest(self.logs / "zoom.us.log"),
            "Library/Logs/zoom.us.log.1": digest(self.logs / "zoom.us.log.1"),
        }
        (self.logs / "zoom.us.logbook-UNRELATED.txt").write_text("unrelated")
        result = self.backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = Path(result.stdout.strip())
        self.assertTrue((snapshot / ".1132fixer-backup").is_file())
        self.assertFalse((snapshot / ".1132fixer-staging").exists())
        manifest = (snapshot / "backup-manifest.txt").read_text()
        for path in STATE_PATHS + ["Library/Logs/zoom.us.log", "Library/Logs/zoom.us.log.1"]:
            self.assertIn("included=" + path + "\n", manifest)
        self.assertNotIn("logbook", manifest)
        self.assertFalse((snapshot / "Logs/zoom.us.logbook-UNRELATED.txt").exists())

        reset = self.reset()
        self.assertEqual(reset.returncode, 0, reset.stderr)
        recovered = {
            "Library/Application Support/zoom.us/session.db": digest(snapshot / "zoom.us/session.db"),
            "Library/Preferences/us.zoom.xos.plist": digest(snapshot / "us.zoom.xos.plist"),
            "Library/Logs/zoom.us.log": digest(snapshot / "Logs/zoom.us.log"),
            "Library/Logs/zoom.us.log.1": digest(snapshot / "Logs/zoom.us.log.1"),
        }
        self.assertEqual(before, recovered)

    # F-041: abandoned staging is pruned only with ownership/age evidence.
    def staging(self, name, metadata=None, age_seconds=0):
        root = self.home / BACKUP_ROOT
        root.mkdir(parents=True, exist_ok=True)
        path = root / name
        path.mkdir()
        (path / "payload").write_text("private session fragment")
        if metadata is not None:
            (path / ".1132fixer-staging").write_text(metadata)
        stamp = time.time() - age_seconds
        for item in [path / "payload", path / ".1132fixer-staging", path]:
            if item.exists():
                os.utime(item, (stamp, stamp))
        return path

    def dead_pid(self):
        process = subprocess.Popen(["/bin/true"])
        process.wait()
        return process.pid

    def test_abandoned_staging_is_pruned_but_active_and_recent_staging_survive(self):
        now = int(time.time())
        dead = self.staging(".incomplete.dead1", f"format=1\npid={self.dead_pid()}\nboot=\nstarted_epoch={now - 7200}\n", 7200)
        other_boot = self.staging(".incomplete.boot1", f"format=1\npid={os.getpid()}\nboot=old-boot\nstarted_epoch={now - 7200}\n", 7200)
        active = self.staging(".incomplete.live1", f"format=1\npid={os.getpid()}\nboot=\nstarted_epoch={now - 7200}\n", 7200)
        recent = self.staging(".incomplete.new01", f"format=1\npid={self.dead_pid()}\nboot=\nstarted_epoch={now - 60}\n", 60)
        legacy_old = self.staging(".incomplete.leg01", None, 10 * 86400)
        legacy_recent = self.staging(".incomplete.leg02", None, 86400)
        unparsable = self.staging(".incomplete.bad01", "format=1\npid=x\n", 7200)
        result = self.backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(dead.exists())
        self.assertFalse(other_boot.exists())
        self.assertFalse(legacy_old.exists())
        self.assertTrue(active.exists(), "a live owner in this boot keeps its staging")
        self.assertTrue(recent.exists(), "age under an hour is never pruned")
        self.assertTrue(legacy_recent.exists())
        self.assertTrue(unparsable.exists())

    def test_symlinked_staging_decoy_is_never_followed(self):
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        old = time.time() - 30 * 86400
        os.utime(outside / "keep", (old, old))
        os.utime(outside, (old, old))
        root = self.home / BACKUP_ROOT
        root.mkdir(parents=True)
        (root / ".incomplete.link01").symlink_to(outside)
        result = self.backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((root / ".incomplete.link01").is_symlink())
        self.assertTrue((outside / "keep").exists())

    def test_rendered_scripts_have_no_unexpanded_interpolation(self):
        for script in [reset_script(str(self.home)), backup_script(str(self.home))]:
            self.assertNotIn("\\(Zoom", script)
            self.assertIn("__1132_zoom_log_candidates", script)


if __name__ == "__main__":
    unittest.main()
