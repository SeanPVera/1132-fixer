# Development and native verification

The application targets Swift 5.9 syntax and macOS 13 APIs. Tests use the Swift
Testing framework (`import Testing`) and require Swift 6 / Xcode 16 or newer.
CI builds and tests on the GitHub-hosted `macos-15`, `macos-15-intel`, `macos-26`
and `macos-26-intel` images (each job has a 30-minute limit); the `macos-15` job
keeps the `Build & Test (macOS)` check name. Release and DMG builds use
`macos-15`. GitHub retired its macOS 13 and 14 images, so a passing hosted build
does not establish behavior on macOS 13 or 14.

Initialize the pinned design-system submodule before building or testing:

```sh
git submodule update --init --recursive
swift build
swift test
swift build -c release
```

CI requires the canonical token JSON and explicitly discovers and runs the real
sandbox profile and disposable-keychain canaries. Missing `sandbox-exec` fails
the canary. macOS 13/14 and Rosetta runs remain required native evidence on
owner hardware or a VM; only labels listed as available in
`actions/runner-images` are used.

If a CLT installation reports a Swift Testing macro/plugin loading failure,
record `xcode-select -p`, `xcrun --find swift`, `swift --version`, and
`xcodebuild -version`. First verify that the selected developer directory belongs
to the installed Xcode containing the intended compiler and SDK. Use a
session-specific `DEVELOPER_DIR` to select an already-installed compatible Xcode
when appropriate. Do not hardcode a machine-specific macro/plugin path into
`Package.swift`, install a toolchain, or change global developer settings under
the remediation's existing authority.

Portable fixtures use Python 3's standard library and a disposable filesystem:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
bash -n scripts/build-universal-dmg.sh scripts/check-dmg.sh
bash design-system/scripts/brand-assets.sh check . .brand-assets.tsv
shellcheck scripts/*.sh
```

When a Swift toolchain is already present on Linux, `find Sources Tests -name
'*.swift' -print0 | xargs -0 swiftc -parse` checks syntax only. SwiftUI and AppKit
do not exist there, so a Linux type-check or test run needs out-of-tree shims and
is never a substitute for the macOS build and test gates.

The application reports the packaged `CFBundleShortVersionString` centrally
through `AppConfiguration.appVersion`. SwiftPM development runs without app
metadata report `dev`. `VERSION` is authoritative for packaging; the packaging
script patches the Info.plist. Log retention is 2,000 entries and 512 KiB, with
32 KiB per entry. Report attachments retain essential metadata and newest activity
within a complete 1,048,576-byte UTF-8 budget.

## Release gates

The owner confirmed `SeanPVera/1132-fixer` as the release/update repository.
Publication is confined to that repository; manual build workflows remain
available. Existing code owners are retained, with canonical-owner coverage
extended to release workflows, scripts, and tests. The original project's
license attribution URL remains intact.

Repository settings were not available through the connected tool surface.
Before enabling publication, the owner must verify:

- Protected `main` requires the macOS build/test, Linux fixture, and brand jobs,
  code-owner review, and appropriate approval of sensitive changes.
- A tag ruleset protects `v*` creation/update/deletion; release tags match VERSION
  and point to reviewed commits reachable from `main`.
- `release-signing` permits only approved release refs, requires independent
  reviewers, and scopes signing/notarization and write-only report credentials.
- Fork and pull-request jobs cannot obtain that environment's credentials.

The release workflow tests its exact checked-out commit before signing and
checks the tested SHA and a clean tracked tree before publication. Workflow
outputs enter shell commands through environment variables. Package validation
requires valid resources in both flat and structured SwiftPM bundles. Developer
ID distributions require endpoint/token resources and run the packaged lookup
canary from the mounted app. Configuration values are never printed.

Inspect packaging scripts before running them: they recreate `dist` and their
build staging directory, can import certificates, and can notarize. They support
`SIGN_IDENTITY=- NOTARIZE=0` for ad-hoc builds; there is no `--unsigned` option.
An unprivileged ad-hoc build in an isolated workspace is within local-verification
scope after inspection, provided pre-existing artifacts are preserved and the
developer-settings file cannot override ad-hoc mode. For example, use
`APPLE_DEVELOPER_FILE=/dev/null SIGN_IDENTITY=- NOTARIZE=0` in a clean disposable
copy. Production signing/notarization credentials require separate authorization.

## Outstanding native evidence

Use a disposable macOS VM/account and fixture data. Do not reset real Zoom data
or mutate a live network interface under the current authorization.

1. Build debug/release, run the full suite and both explicit canaries, then start
   `swift run` and check immediate startup. Inspect narrow/regular window layouts,
   warnings/failures, quick-launch wording, and accessibility with the existing
   design tokens.
2. Check ordinary and delayed authorization, actual authorization cancellation,
   watchdog expiry, child cleanup/restoration, app cancellation, two app instances,
   and crash/relaunch. Observe real root descendants. An outer timeout and a
   completion marker alone do not establish process-tree settlement. Unknown
   completion must block launch/repair; the unprivileged ownership file remains
   locked while the app is alive and the pending boot marker survives relaunch.
3. Verify BSD `pgrep`/`pkill` UID and literal-name behavior. A disposable
   `zoomXus` process must survive Zoom selectors; another user's Zoom cannot
   satisfy success. Prove that the tracked sandbox-exec child remains the actual
   Zoom executable; process replacement, relaunch, or unknown provenance must
   fail closed. Verify final signature failure/missing codesign blocks launch.
4. Exercise real signed Zoom startup, login/SSO, helper behavior, camera,
   microphone, keychain, and TCC attribution on supported OS/hardware combinations.
   The sandbox is a selected denylist with the real home and accessible keychain.
5. After inspecting the script and preserving existing artifacts, make an ad-hoc
   native artifact in the isolated workspace and run
   `scripts/check-dmg.sh <actual-dmg> adhoc 0`. Developer ID/notarization validation
   needs separately authorized credentials. Validate the mounted downloaded DMG,
   both architecture slices, entitlements, version/minimum OS, runtime resource
   lookup, signatures, notarization ticket, and successful mount cleanup.

## Deferred scope expansion and measurements

No Zoom deletion scope or Group Containers restriction was expanded. A real,
versioned signed Zoom bundle and its state were unavailable. Before expanding
scope, inventory ownership and contents, entitlements/application groups, and
actual storage use; preserve relative paths, add a restore manifest and parent/
symlink protections, compare restored fixture hashes, update consent, then pass
the real Zoom startup/SSO/media gates. Do not kill `cfprefsd` or add broad Group
Containers restrictions without demonstrated need and compatibility evidence.

Signature-overhead benchmarking, Darwin pipe/thread/descriptor stress with
detached descendants, signing-job separation, and a declarative step runner
remain conditional on measurements and stable native regression coverage. The
final pinned signature check and ProcessExecutor were preserved. The existing
checkout v7 pin in `brand.yml` was preserved as directed.
