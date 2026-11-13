#!/usr/bin/env python3
"""Validate either SwiftPM bundle layout without printing configuration values."""
import argparse
from pathlib import Path
import struct
import unicodedata
from urllib.parse import urlsplit
import zlib


def resource_path(bundle, name):
    candidates = [bundle / name, bundle / "Contents/Resources" / name]
    found = [p for p in candidates if p.is_file() and not p.is_symlink()]
    if len(found) != 1:
        raise ValueError(f"Missing or ambiguous required resource: {name}")
    if not found[0].stat().st_size:
        raise ValueError(f"Empty required resource: {name}")
    return found[0]


def validate_png(path):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("AppIcon.png is not a PNG")
    offset, kinds, compressed = 8, [], bytearray()
    while offset + 12 <= len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + size
        if end > len(data):
            raise ValueError("Truncated AppIcon.png")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:end - 4]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != crc:
            raise ValueError("Invalid AppIcon.png checksum")
        if kind == b"IHDR" and (len(payload) != 13 or not all(struct.unpack(">II", payload[:8]))):
            raise ValueError("Invalid AppIcon.png dimensions")
        if kind == b"IDAT":
            compressed.extend(payload)
        kinds.append(kind)
        offset = end
        if kind == b"IEND":
            break
    if offset != len(data) or not kinds or kinds[0] != b"IHDR" or kinds[-1] != b"IEND" or b"IDAT" not in kinds:
        raise ValueError("Invalid AppIcon.png structure")
    try:
        if not zlib.decompress(compressed):
            raise ValueError("Empty AppIcon.png image data")
    except zlib.error as error:
        raise ValueError("Invalid AppIcon.png image data") from error


def config_value(bundle, name):
    path = resource_path(bundle, name)
    if path.stat().st_size > 16_384:
        raise ValueError(f"Oversized configuration resource: {name}")
    value = path.read_text(encoding="utf-8").strip()
    if not value or any(unicodedata.category(c) == "Cc" for c in value):
        raise ValueError(f"Invalid configuration resource: {name}")
    return value


def validate(bundle, require_bug_report=False):
    validate_png(resource_path(bundle, "AppIcon.png"))
    if require_bug_report:
        endpoint = config_value(bundle, "FIXER_BUG_REPORT_ENDPOINT")
        url = urlsplit(endpoint)
        if url.scheme.lower() != "https" or not url.hostname or url.username is not None or url.password is not None:
            raise ValueError("Invalid bug-report endpoint configuration")
        config_value(bundle, "FIXER_BUG_REPORT_TOKEN")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--require-bug-report", action="store_true")
    args = parser.parse_args()
    try:
        validate(args.bundle, args.require_bug_report)
    except (ValueError, OSError, UnicodeError):
        parser.exit(1, "Required packaged resources are missing, ambiguous, empty, or invalid.\n")
    print("Packaged resource validation passed.")
