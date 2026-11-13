import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_acceptance", ROOT / "scripts/check-native-acceptance.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class NativeAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        (self.root / "Sources").mkdir()
        (self.root / "Sources/app.swift").write_text("// fixture source; not a native acceptance run\n")
        (self.root / "VERSION").write_text("1.8.7\n")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Fixture baseline")
        self.source = self.git("rev-parse", "HEAD")
        self.artifact = self.root / "docs/native-evidence/fixture.txt"
        self.artifact.parent.mkdir(parents=True)
        self.artifact.write_text("Synthetic fixture for validator tests. No platform behavior is attested.\n")
        base_record = {
            "tested_by": "fixture", "tested_at": datetime.now(timezone.utc).isoformat(),
            "host_os": "macOS", "macos_version": "15.0", "hardware": "apple_silicon",
            "architecture": "arm64", "translated": False, "zoom_version": "fixture-6.0",
            "artifacts": [{"path": "docs/native-evidence/fixture.txt", "sha256": hashlib.sha256(self.artifact.read_bytes()).hexdigest()}],
        }
        self.document = {"schema_version": 1, "application_version": "1.8.7", "source_commit": self.source, "checks": []}
        for check_id in GATE.REQUIRED_CHECKS:
            record = copy.deepcopy(base_record)
            if check_id in ("macos-13", "macos-14"):
                record["macos_version"] = check_id[-2:] + ".0"
            if check_id == "rosetta":
                record.update(architecture="x86_64", translated=True)
            records = [record]
            if check_id in ("macos-13", "macos-14"):
                intel = copy.deepcopy(record)
                intel.update(hardware="intel", architecture="x86_64")
                records.append(intel)
            self.document["checks"].append({"id": check_id, "status": "pass", "records": records})

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True).strip()

    def errors(self):
        return GATE.validate(self.document, self.root)

    def test_complete_fixture_with_matching_sources_is_valid(self):
        self.assertEqual(self.errors(), [])

    def test_every_missing_failed_or_unverified_native_check_blocks(self):
        original = copy.deepcopy(self.document)
        for index in range(len(GATE.REQUIRED_CHECKS)):
            for status in ("unverified", "failed", "", None):
                self.document = copy.deepcopy(original)
                self.document["checks"][index]["status"] = status
                self.assertTrue(self.errors())

    def test_duplicate_missing_and_unknown_ids_block(self):
        for ids in ([GATE.REQUIRED_CHECKS[0]] * 8, list(GATE.REQUIRED_CHECKS[:-1]), list(GATE.REQUIRED_CHECKS) + ["unexpected"]):
            document = copy.deepcopy(self.document)
            document["checks"] = [{"id": value, "status": "pass", "records": []} for value in ids]
            self.assertTrue(GATE.validate(document, self.root))

    def test_wrong_version_or_unavailable_commit_blocks(self):
        self.document["application_version"] = "1.0.0"
        self.assertTrue(self.errors())
        self.document["application_version"] = "1.8.7"
        for commit in ("deadbeef", "0" * 40, None):
            self.document["source_commit"] = commit
            self.assertTrue(self.errors())

    def test_uncommitted_and_committed_source_changes_require_retesting(self):
        (self.root / "Sources/app.swift").write_text("// changed source\n")
        self.assertTrue(self.errors())
        self.git("add", "Sources")
        self.git("commit", "--quiet", "-m", "Changed runtime")
        self.assertTrue(self.errors())

    def test_new_untracked_release_input_blocks(self):
        (self.root / "Sources/new.swift").write_text("// new runtime input\n")
        self.assertTrue(self.errors())

    def test_evidence_only_followup_commit_does_not_invalidate_tested_sources(self):
        self.git("add", "docs")
        self.git("commit", "--quiet", "-m", "Record fixture evidence")
        self.assertEqual(self.errors(), [])

    def test_hash_mismatch_missing_artifact_and_symlink_block(self):
        self.artifact.write_text("different evidence\n")
        self.assertTrue(self.errors())
        self.artifact.unlink()
        self.assertTrue(self.errors())
        self.artifact.symlink_to(self.root / "VERSION")
        self.assertTrue(self.errors())

    def test_artifact_traversal_and_symlinked_parent_block(self):
        self.document["checks"][0]["records"][0]["artifacts"][0]["path"] = "docs/native-evidence/../../VERSION"
        self.assertTrue(self.errors())
        self.document["checks"][0]["records"][0]["artifacts"][0]["path"] = "docs/native-evidence/linked/VERSION"
        (self.artifact.parent / "linked").symlink_to(self.root, target_is_directory=True)
        self.assertTrue(self.errors())

    def test_platform_timestamp_and_translation_metadata_must_be_consistent(self):
        record = self.document["checks"][0]["records"][0]
        original = copy.deepcopy(record)
        for field, value in (("host_os", "Linux"), ("tested_at", None), ("tested_at", "2026-01-01T00:00:00"), ("tested_at", "2999-01-01T00:00:00+00:00"), ("architecture", "x86_64"), ("translated", "false")):
            record.clear()
            record.update(original)
            record[field] = value
            self.assertTrue(self.errors())

    def test_older_os_requires_both_hardware_families_and_rosetta_requires_translation(self):
        for entry in self.document["checks"]:
            if entry["id"] == "macos-13":
                entry["records"] = entry["records"][:1]
        self.assertTrue(self.errors())
        for entry in self.document["checks"]:
            if entry["id"] == "rosetta":
                entry["records"][0].update(architecture="arm64", translated=False)
        self.assertTrue(self.errors())

    def test_cli_missing_or_malformed_evidence_exits_nonzero(self):
        path = self.root / "missing.json"
        for content in (None, "{", "null", '{"schema_version":1,"schema_version":1}'):
            if content is not None:
                path.write_text(content)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/check-native-acceptance.py"), "--root", str(self.root), "--evidence", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("BLOCKED", result.stdout)
