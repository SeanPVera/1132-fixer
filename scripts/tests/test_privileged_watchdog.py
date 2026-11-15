"""Run the rendered privileged watchdog wrapper (unprivileged) against fixture bodies.

Covers the deadline for foreground work, descendant cleanup, bounded cleanup when a
body ignores SIGTERM, restore traps, and the per-run completion marker. These do not
exercise AppleScript or root; Darwin runs the same checks in the Swift suite.
"""
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

from swift_fragments import literal_after, render

BASH = os.environ.get("FIXTURE_BASH", "/bin/bash")
TEMPLATE = literal_after("static func makeTimeBoundedCommand")


def bounded(body, limit=1, grace=1, marker=None):
    # Mirrors the Swift `completionLine` (a single-quoted marker printed by the top level).
    completion = ":" if marker is None else f"printf '\\n%s=%s\\n' '{marker}' \"$__1132_body_status\""
    return render(TEMPLATE, limit=limit, grace=grace, graceTicks=grace * 5, command=body,
                  completionLine=completion)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie still answers kill(0); treat it as gone.
    try:
        with open(f"/proc/{pid}/stat") as handle:
            return handle.read().split(") ")[-1].split()[0] != "Z"
    except FileNotFoundError:
        return True


class PrivilegedWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)

    def run_bounded(self, body, **kwargs):
        started = time.monotonic()
        result = subprocess.run([BASH, "-c", bounded(body, **kwargs)], capture_output=True, text=True, timeout=60)
        return result, time.monotonic() - started

    # F-006: a foreground command can no longer outlive the deadline.
    def test_foreground_command_is_stopped_at_the_deadline(self):
        result, elapsed = self.run_bounded("/bin/sleep 6")
        self.assertEqual(result.returncode, 143)
        self.assertLess(elapsed, 3.5)

    def test_fast_body_keeps_its_status_and_output(self):
        result, elapsed = self.run_bounded("echo hi; exit 3", limit=5)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout, "hi\n")
        self.assertLess(elapsed, 3)

    # F-007: owned descendants are stopped, not left running.
    def test_nested_descendants_are_stopped(self):
        pid_file = self.dir / "pid"
        result, _ = self.run_bounded(f"( /bin/sleep 30 & echo $! > '{pid_file}'; wait )")
        self.assertEqual(result.returncode, 143)
        pid = int(pid_file.read_text())
        deadline = time.monotonic() + 2
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(pid))

    # F-007: cleanup is bounded even when the body ignores SIGTERM.
    def test_stalled_cleanup_is_force_stopped_after_the_grace_period(self):
        result, elapsed = self.run_bounded("trap '' TERM; /bin/sleep 20", limit=1, grace=1)
        self.assertEqual(result.returncode, 143)
        self.assertLess(elapsed, 5)
        self.assertIn("force-stopped", result.stderr)

    def test_restore_trap_runs_within_the_grace_period(self):
        marker = self.dir / "restored"
        body = f"( trap 'echo restored > \"{marker}\"' EXIT; trap 'exit 1' TERM; /bin/sleep 30 & wait $! )"
        result, _ = self.run_bounded(body, limit=1, grace=3)
        self.assertEqual(result.returncode, 143)
        self.assertEqual(marker.read_text().strip(), "restored")

    def test_completion_marker_is_printed_only_after_the_body_finishes_in_time(self):
        marker = "__1132_PRIVILEGED_COMPLETE_0123456789ABCDEF0123456789ABCDEF__"
        for body in ["/bin/sleep 6", "/bin/sleep 6; exit 0", "trap '' TERM; /bin/sleep 6"]:
            result, _ = self.run_bounded(body, marker=marker)
            self.assertEqual(result.returncode, 143)
            self.assertNotIn(marker, result.stdout, body)
        finished, _ = self.run_bounded("echo body; exit 4", limit=5, marker=marker)
        self.assertEqual(finished.returncode, 4)
        self.assertTrue(finished.stdout.endswith(f"\n{marker}=4\n"), finished.stdout)

    def test_body_cannot_forge_the_marker_line_shape(self):
        # The body can print text, but the parser accepts exactly one marker line; a forged
        # copy makes two lines, which the Swift side rejects as invalid evidence.
        marker = "__1132_PRIVILEGED_COMPLETE_0123456789ABCDEF0123456789ABCDEF__"
        result, _ = self.run_bounded(f"echo {marker}=0", limit=5, marker=marker)
        self.assertEqual(result.stdout.count(marker), 2)


if __name__ == "__main__":
    unittest.main()
