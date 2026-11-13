#!/usr/bin/env python3
"""Fail closed unless reviewed native evidence matches the release sources.

This validates evidence integrity and scope. It does not perform or attest to
interactive Zoom, media, or administrator tests.
"""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

REQUIRED_CHECKS = (
    "zoom-startup-sso", "camera-microphone-keychain", "privileged-lifecycle",
    "launch-provenance", "macos-13", "macos-14", "rosetta", "ui-accessibility",
)
RELEASE_INPUTS = ("Sources", "Package.swift", "VERSION", "MIN_MACOS_VERSION", "scripts", ".github/workflows")


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate keys in native evidence")
        result[key] = value
    return result


def git(root, *arguments):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Cannot verify the evidence source commit against this checkout")
    return result.stdout.strip()


def artifact_matches(root, artifact):
    if not isinstance(artifact, dict):
        return False
    name, digest = artifact.get("path"), artifact.get("sha256")
    if not isinstance(name, str) or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return False
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts or not name.startswith("docs/native-evidence/"):
        return False
    path = root / relative
    if not path.is_file() or not 0 < path.stat().st_size <= 8 * 1024 * 1024:
        return False
    ancestor = path
    while ancestor != root:
        if ancestor.is_symlink() or ancestor == ancestor.parent:
            return False
        ancestor = ancestor.parent
    return hashlib.sha256(path.read_bytes()).hexdigest() == digest


def valid_record(root, record, check_id):
    if not isinstance(record, dict):
        return False
    try:
        if not isinstance(record.get("tested_by"), str) or not record["tested_by"].strip():
            return False
        if not isinstance(record.get("tested_at"), str):
            return False
        when = datetime.fromisoformat(record["tested_at"].replace("Z", "+00:00"))
        if when.tzinfo is None or when > datetime.now(timezone.utc) + timedelta(minutes=5):
            return False
        if record.get("host_os") != "macOS" or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", record["macos_version"]):
            return False
        major = int(record["macos_version"].split(".")[0])
        if major < 13 or not isinstance(record.get("zoom_version"), str) or not record["zoom_version"].strip():
            return False
        hardware, architecture, translated = record["hardware"], record["architecture"], record["translated"]
        if type(translated) is not bool or (hardware, architecture, translated) not in (
            ("intel", "x86_64", False), ("apple_silicon", "arm64", False), ("apple_silicon", "x86_64", True),
        ):
            return False
        if check_id in ("macos-13", "macos-14") and major != int(check_id[-2:]):
            return False
        if check_id == "rosetta" and not translated:
            return False
        artifacts = record.get("artifacts")
        return isinstance(artifacts, list) and bool(artifacts) and all(artifact_matches(root, a) for a in artifacts)
    except (KeyError, TypeError, ValueError, OSError):
        return False


def validate(document, root):
    root = root.resolve()
    errors = []
    if not isinstance(document, dict) or type(document.get("schema_version")) is not int or document["schema_version"] != 1:
        return ["Missing or unsupported native-evidence schema"]
    if document.get("application_version") != (root / "VERSION").read_text().strip():
        errors.append("Native evidence does not match VERSION")
    source = document.get("source_commit", "")
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        errors.append("Native evidence needs a full tested source commit SHA")
    else:
        try:
            git(root, "rev-parse", "--verify", source + "^{commit}")
            git(root, "merge-base", "--is-ancestor", source, "HEAD")
            if git(root, "diff", "--name-only", source, "HEAD", "--", *RELEASE_INPUTS):
                errors.append("Release inputs changed after the native tests; repeat affected acceptance on this candidate")
            if git(root, "status", "--porcelain=v1", "--untracked-files=all", "--", *RELEASE_INPUTS):
                errors.append("Release inputs have uncommitted changes")
        except ValueError as error:
            errors.append(str(error))
    checks = document.get("checks")
    if not isinstance(checks, list) or any(not isinstance(c, dict) for c in checks):
        return errors + ["Native checks must be an explicit list"]
    identifiers = [c.get("id") for c in checks]
    if len(identifiers) != len(REQUIRED_CHECKS) or set(x for x in identifiers if isinstance(x, str)) != set(REQUIRED_CHECKS):
        errors.append("Native check IDs must include each required check exactly once")
    for check_id in REQUIRED_CHECKS:
        entries = [c for c in checks if c.get("id") == check_id]
        if len(entries) != 1 or entries[0].get("status") != "pass":
            errors.append(check_id + ": native acceptance has not passed")
            continue
        records = entries[0].get("records")
        if not isinstance(records, list) or not records or not all(valid_record(root, r, check_id) for r in records):
            errors.append(check_id + ": missing or invalid native records/artifact hashes")
        elif check_id in ("macos-13", "macos-14") and {r["hardware"] for r in records if not r["translated"]} != {"intel", "apple_silicon"}:
            errors.append(check_id + ": native Intel and Apple silicon evidence are both required")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--evidence", type=Path, default=Path(".github/native-acceptance.json"))
    args = parser.parse_args()
    try:
        path = args.evidence if args.evidence.is_absolute() else args.root / args.evidence
        if path.is_symlink() or not 0 < path.stat().st_size <= 1024 * 1024:
            raise ValueError("Invalid native-evidence file")
        errors = validate(json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys), args.root)
    except (OSError, ValueError, UnicodeError):
        errors = ["Native acceptance evidence is missing or invalid"]
    if errors:
        print("BLOCKED: native acceptance is incomplete")
        for error in errors:
            print("- " + error)
        return 1
    print("Native acceptance evidence integrity and source checks passed; signed artifact gates still apply.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
