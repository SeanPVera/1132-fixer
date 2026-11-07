"""Execute extracted production shell fragments only against disposable fixtures.

These checks do not establish Darwin process or sandbox behavior.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "Sources/1132Fixer/ShellCommands.swift").read_text()


class ShellFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def retention(self, count=5, cap_kb=1024):
        start = SOURCE.index('        (\n          cd "$backup_root"')
        end = SOURCE.index('\n\n        if [ ! -d "$backup_dir"', start)
        script = textwrap.dedent(SOURCE[start:end])
        script = script.replace(r"\(firstStaleEntry - 1)", str(count)).replace(r"\(maximumKilobytes)", str(cap_kb))
        self.assertNotIn(r"\(", script)
        env = dict(os.environ, backup_root=str(self.root), current_snapshot="snapshot-current")
        subprocess.run(["/bin/bash", "-c", script], env=env, check=True, capture_output=True, text=True)

    def snapshot(self, name, size, mtime):
        path = self.root / name
        path.mkdir()
        (path / "payload").write_bytes(b"x" * size)
        os.utime(path, (mtime, mtime))
        return path

    def test_oversized_rejected_candidate_does_not_evict_older_small_snapshot(self):
        current = self.snapshot("snapshot-current", 16_384, 30)
        oversized = self.snapshot("snapshot-large", 2_097_152, 20)
        small = self.snapshot("snapshot-small", 16_384, 10)
        self.retention(count=2)
        self.assertTrue(current.exists())
        self.assertFalse(oversized.exists())
        self.assertTrue(small.exists())

    def test_current_snapshot_survives_when_it_alone_exceeds_cap(self):
        current = self.snapshot("snapshot-current", 2_097_152, 30)
        older = self.snapshot("snapshot-small", 16_384, 10)
        self.retention()
        self.assertTrue(current.exists())
        self.assertFalse(older.exists())

    def test_retained_count_counts_current_snapshot(self):
        self.snapshot("snapshot-current", 10, 30)
        old = self.snapshot("snapshot-older", 10, 10)
        self.retention(count=1)
        self.assertFalse(old.exists())

    def stop_script(self):
        start = SOURCE.index('    static let stopZoom = #"""') + len('    static let stopZoom = #"""\n')
        end = SOURCE.index('    """#', start)
        return textwrap.dedent(SOURCE[start:end])

    def fixture_tool(self, name, contents):
        path = self.root / name
        path.write_text("#!/bin/bash\n" + contents)
        path.chmod(0o700)
        return str(path)

    def test_foreign_user_process_cannot_satisfy_shutdown_probe(self):
        log = self.root / "calls"
        pgrep = self.fixture_tool("pgrep", 'printf "%s\\n" "$*" >> "$FIXTURE_CALLS"\n[ "$1" = "-u" ] && [ "$2" = "4242" ] && exit 1\nexit 0\n')
        pkill = self.fixture_tool("pkill", 'echo unexpected-kill >> "$FIXTURE_CALLS"; exit 0\n')
        user_id = self.fixture_tool("id", 'echo 4242\n')
        script = self.stop_script().replace("/usr/bin/pgrep", pgrep).replace("/usr/bin/pkill", pkill).replace("/usr/bin/id", user_id)
        result = subprocess.run(["/bin/bash", "-c", script], env=dict(os.environ, FIXTURE_CALLS=str(log)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("unexpected-kill", log.read_text())
        self.assertTrue(all(line.startswith("-u 4242 -x ") for line in log.read_text().splitlines()))

    def test_surviving_process_causes_refusal_after_scoped_force_kill(self):
        log = self.root / "calls"
        # A filename matching a regex-looking pattern must not glob it back into
        # an unescaped ERE before pkill receives it.
        (self.root / "zoom.us").touch()
        pgrep = self.fixture_tool("pgrep", 'exit 0\n')
        pkill = self.fixture_tool("pkill", 'printf "%s\\n" "$*" >> "$FIXTURE_CALLS"\n')
        user_id = self.fixture_tool("id", 'echo 4242\n')
        pause = self.fixture_tool("pause", 'exit 0\n')
        script = self.stop_script().replace("/usr/bin/pgrep", pgrep).replace("/usr/bin/pkill", pkill).replace("/usr/bin/id", user_id).replace("/bin/sleep", pause)
        result = subprocess.run(["/bin/bash", "-c", script], cwd=self.root, env=dict(os.environ, FIXTURE_CALLS=str(log)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to modify Zoom data", result.stderr)
        self.assertIn("-KILL -u 4242 -x zoom[.]us", log.read_text())

    def test_unrelated_live_pid_is_not_launch_provenance(self):
        start = SOURCE.index("        tracked_sandbox_child_is_running() {")
        end = SOURCE.index("        stop_zoom_processes() {", start)
        function = textwrap.dedent(SOURCE[start:end])
        external = subprocess.Popen(["/bin/sleep", "5"])
        try:
            script = function + '\nuid="$(id -u)"\nzoom_binary="/bin/sleep"\nsandbox_pid="$UNRELATED_PID"\ntracked_sandbox_child_is_running\n'
            result = subprocess.run(["/bin/bash", "-c", script], env=dict(os.environ, UNRELATED_PID=str(external.pid)), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        finally:
            external.terminate()
            external.wait(timeout=5)

    def test_watchdog_parent_selectors_are_unchanged(self):
        watchdog = SOURCE[SOURCE.index("static func makeTimeBoundedCommand"):SOURCE.index("// MARK: - Command Strings")]
        self.assertIn('/usr/bin/pkill -P "$__1132_watchdog"', watchdog)
        self.assertNotIn("pkill -u", watchdog)

    def test_no_unexpanded_interpolations_in_shutdown_script(self):
        self.assertNotRegex(self.stop_script(), re.escape(r"\("))
