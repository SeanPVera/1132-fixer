#!/usr/bin/env bash
set -euo pipefail

# Inspect the artifact users will download, rather than the staging app.
# Usage: check-dmg.sh path/to/file.dmg adhoc|developer-id 0|1
if [[ "${#}" -ne 3 ]]; then
  echo "Usage: $0 DMG_PATH adhoc|developer-id NOTARIZED(0|1)" >&2
  exit 2
fi

DMG_PATH="$1"
SIGNING_MODE="$2"
NOTARIZED="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="1132 Fixer"

case "$SIGNING_MODE:$NOTARIZED" in
  adhoc:0|developer-id:0|developer-id:1) ;;
  *) echo "Invalid signing mode or notarization setting: $SIGNING_MODE/$NOTARIZED" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
  echo "DMG smoke checks require macOS (hdiutil, codesign, and PlistBuddy)." >&2
  exit 2
fi

EXPECTED_VERSION="${APP_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
EXPECTED_MIN_MACOS="${MIN_MACOS:-$(tr -d '[:space:]' < "$ROOT_DIR/MIN_MACOS_VERSION")}"
EXPECTED_BUNDLE_ID="${BUNDLE_ID:-com.1132fixer.1132-Fixer}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

# hdiutil and codesign may resolve relative paths from different directories.
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/1132-fixer-dmg-check.XXXXXX")"
MOUNT_POINT="$TEMP_DIR/mount"
mkdir "$MOUNT_POINT"
MOUNTED=0

cleanup() {
  local status=$?
  local detached=1
  trap - EXIT
  if [[ "$MOUNTED" -eq 1 ]]; then
    if ! hdiutil detach "$MOUNT_POINT" -quiet; then
      echo "Unable to detach DMG at $MOUNT_POINT" >&2
      status=1
      detached=0
    fi
  fi
  if [[ "$detached" -eq 1 ]]; then
    if ! rm -rf "$TEMP_DIR"; then
      echo "Unable to remove temporary directory: $TEMP_DIR" >&2
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

require_plist_value() {
  local actual
  actual="$(plist_value "$1" "$2")"
  if [[ "$actual" != "$3" ]]; then
    echo "Unexpected $2: expected '$3', found '$actual'" >&2
    exit 1
  fi
}

echo "==> Verifying DMG integrity and signature"
hdiutil verify "$DMG_PATH" >/dev/null
codesign --verify --verbose=2 "$DMG_PATH"
DMG_SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$DMG_PATH" 2>&1)"
if [[ "$SIGNING_MODE" == adhoc ]]; then
  [[ "$DMG_SIGNATURE_DETAILS" == *"Signature=adhoc"* ]] || {
    echo "Expected an ad-hoc DMG signature" >&2
    exit 1
  }
else
  [[ "$DMG_SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] || {
    echo "Expected a Developer ID Application DMG signature" >&2
    exit 1
  }
fi

echo "==> Mounting DMG read-only"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" "$DMG_PATH" >/dev/null
MOUNTED=1

APP_PATH="$MOUNT_POINT/$APP_NAME.app"
CONTENTS="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS/Info.plist"
EXECUTABLE="$CONTENTS/MacOS/$APP_NAME"
RESOURCE_BUNDLE="$CONTENTS/Resources/1132 Fixer_1132Fixer.bundle"

[[ -d "$APP_PATH" && -f "$INFO_PLIST" && -x "$EXECUTABLE" ]] || {
  echo "DMG is missing the app bundle, Info.plist, or executable" >&2
  exit 1
}
[[ -L "$MOUNT_POINT/Applications" && "$(readlink "$MOUNT_POINT/Applications")" == /Applications ]] || {
  echo "DMG is missing the /Applications shortcut" >&2
  exit 1
}
[[ -s "$CONTENTS/Resources/AppIcon.icns" && -s "$RESOURCE_BUNDLE/AppIcon.png" ]] || {
  echo "Packaged app is missing its Finder icon or SwiftPM resource bundle" >&2
  exit 1
}
[[ ! -e "$CONTENTS/Resources/AppIcon.png" ]] || {
  echo "Packaged app contains a redundant root AppIcon.png" >&2
  exit 1
}

plutil -lint "$INFO_PLIST" >/dev/null
require_plist_value "$INFO_PLIST" CFBundleName "$APP_NAME"
require_plist_value "$INFO_PLIST" CFBundleExecutable "$APP_NAME"
require_plist_value "$INFO_PLIST" CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
require_plist_value "$INFO_PLIST" CFBundleShortVersionString "$EXPECTED_VERSION"
require_plist_value "$INFO_PLIST" LSMinimumSystemVersion "$EXPECTED_MIN_MACOS"
require_plist_value "$INFO_PLIST" CFBundleSupportedPlatforms:0 MacOSX
if [[ -n "${APP_BUILD:-}" ]]; then
  require_plist_value "$INFO_PLIST" CFBundleVersion "$APP_BUILD"
fi

echo "==> Checking universal executable and app signature"
ARCHITECTURES=" $(lipo -archs "$EXECUTABLE") "
[[ "$ARCHITECTURES" == *" arm64 "* && "$ARCHITECTURES" == *" x86_64 "* ]] || {
  echo "Packaged executable must contain arm64 and x86_64 slices: $ARCHITECTURES" >&2
  exit 1
}
codesign --verify --strict --deep --verbose=2 "$APP_PATH"

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$APP_PATH" 2>&1)"
if [[ "$SIGNING_MODE" == adhoc ]]; then
  [[ "$SIGNATURE_DETAILS" == *"Signature=adhoc"* ]] || {
    echo "Expected an ad-hoc app signature" >&2
    exit 1
  }
else
  [[ "$SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] || {
    echo "Expected a Developer ID Application signature" >&2
    exit 1
  }
fi

ENTITLEMENTS_PLIST="$TEMP_DIR/entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null
plutil -lint "$ENTITLEMENTS_PLIST" >/dev/null
require_plist_value "$ENTITLEMENTS_PLIST" com.apple.security.device.camera true
require_plist_value "$ENTITLEMENTS_PLIST" com.apple.security.device.audio-input true
if plist_value "$ENTITLEMENTS_PLIST" com.apple.security.app-sandbox >/dev/null 2>&1; then
  echo "App Sandbox entitlement must be absent for the Zoom launch workflow" >&2
  exit 1
fi

if [[ "$NOTARIZED" == 1 ]]; then
  echo "==> Validating stapled notarization ticket"
  xcrun stapler validate "$DMG_PATH"
fi

echo "DMG smoke check passed: $DMG_PATH"
