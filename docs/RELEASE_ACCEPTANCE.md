# Complete native acceptance and distribution

The candidate is **1.8.8**, bumped once from main's 1.8.7 under the repository
version rule for the release-check code. Application runtime and sandbox code
are unchanged. Publication remains blocked. The release workflow now requires
`.github/native-acceptance.json` before it can import signing credentials.

The checker validates source identity, evidence metadata and artifact hashes.
It does not perform or certify interactive testing. A passing fixture is not
native acceptance evidence; do not copy test-fixture records into the manifest.

## Available verified starting point

Main commit `4df69c48ab0abce63ce8a53f18bafac8799d3b2a` has passing
[CI run 43342078046](https://github.com/SeanPVera/1132-fixer/actions/runs/43342078046)
and [Build DMG run 43342767190](https://github.com/SeanPVera/1132-fixer/actions/runs/43342767190).
The latter built, mounted, smoke-checked and uploaded a universal **ad-hoc** DMG.
It reported no configured Apple certificate and performed no notarization.
These runs cover the baseline; require green CI for the new candidate too.

The first candidate run stalled on one Intel runner. Its single-job retry
compiled successfully and then exposed two two-second process-I/O test limits
under host contention. The three I/O-semantics tests now allow ten seconds;
production executor deadlines, the dedicated 0.1-second timeout test and the
four-second cancellation assertion remain unchanged. This corrects a test
scheduling assumption and does not count as privileged process-lifecycle proof.
The corrected tests passed all four platform jobs in
[CI run 43428981062](https://github.com/SeanPVera/1132-fixer/actions/runs/43428981062)
at `17ad7cc4a2eb0be67e9a508f20945e25ff4f743a`, including debug/release builds
and sandbox, keychain and shutdown canaries. Require green checks on the final
PR head as well.

An ad-hoc test installer is available from
[Build DMG run 43424698062](https://github.com/SeanPVera/1132-fixer/actions/runs/43424698062/artifacts/14037210350).
It contains application sources at `a9048593140c79a1ffc36bd635c1aeccb2b92b8f`;
subsequent candidate changes affect tests, documentation and the release-evidence
checker. Its SHA-256 is
`36599cadcb40b0c44656c1b1812ddd99f5bcc96b924d24399a0367d381175b9a`.
The hosted build mounted and smoke-checked the DMG; local ZIP CRC and DMG hash
checks also passed. It is not notarized or approved for public distribution.

## Real-Mac procedure

Use a disposable account or VM, fixture state and an approved test Zoom account.
No reset of a normal user account or mutation of a live production interface is
authorized by these instructions. Administrator/network experiments need a
separately authorized isolated environment. Test both repair and sandbox-only
launch. Do not infer sandbox provenance from another process with the same name.

1. Check out the candidate, initialize its pinned submodule, and record
   `git rev-parse HEAD`, `sw_vers`, `uname -m`, Xcode/Swift versions and the signed
   Zoom version. Use the existing DEVELOPMENT.md build/canary commands.
2. Run the checklist below and keep sanitized observations under
   `docs/native-evidence/`. Record exact actions, results, relevant process
   identities and expected failure behavior. Do not record account credentials,
   meeting details, contact information, raw MACs or signing secrets.
3. Add a native record to the corresponding manifest entry only after that check
   passes. Use `failed` for an observed failure, or leave `unverified` when not
   performed. Fix failures and repeat affected checks.
4. Set `source_commit` to the full candidate commit actually tested. The checker
   requires that commit to be an ancestor of the release checkout, with identical
   Sources, Package.swift/Package.resolved, VERSION, MIN_MACOS_VERSION, scripts,
   packaging assets, the design-system pin/content, .gitmodules and workflow files.
   A following evidence/docs commit is allowed. Changing a release input requires
   affected acceptance again; the checker never accepts stale source evidence.
5. Run `python3 scripts/check-native-acceptance.py`. A nonzero result blocks
   signing/publication. Submit the completed evidence for independent review.

| Manifest ID | Required observation |
|---|---|
| `zoom-startup-sso` | Actual signed Zoom starts under the required sandbox; login and SSO complete; repair and launch-only results describe observed behavior. |
| `camera-microphone-keychain` | Actual camera capture, microphone capture/playback and disposable keychain access work; record TCC/helper attribution and both launcher/Zoom prompts. |
| `privileged-lifecycle` | Ordinary/delayed authorization, true authorization cancellation, watchdog expiry and restoration, root descendant settlement, UI stop, two instances, crash/relaunch and reboot behavior. Unknown completion prevents further mutation and launch. |
| `launch-provenance` | Track the launched child/UID/executable through actual Zoom startup; process replacement, PID uncertainty, foreign-user Zoom and failed final pinned signature cannot establish success. |
| `macos-13` | Real startup, repair/launch-only, media/keychain and failure boundaries on macOS 13, with native Intel and native Apple silicon records. |
| `macos-14` | The same supported behavior on macOS 14, with native Intel and native Apple silicon records. |
| `rosetta` | Apple silicon executing x86_64 through Rosetta; accurate hardware/execution capability and the same sandbox, media and failure boundaries. |
| `ui-accessibility` | Startup and real workflow results at narrow/regular window sizes; warnings/failures/backup provenance, keyboard operation and VoiceOver labels match execution. |

Each record has this shape (replace every placeholder with an actual observation):

```json
{
  "tested_by": "GitHub login of the person who performed the check",
  "tested_at": "ISO-8601 timestamp with time zone",
  "host_os": "macOS",
  "macos_version": "actual major.minor.patch",
  "hardware": "intel or apple_silicon",
  "architecture": "x86_64 or arm64",
  "translated": false,
  "zoom_version": "actual signed Zoom version/build",
  "artifacts": [
    {"path": "docs/native-evidence/actual-sanitized-record.txt", "sha256": "actual 64-character lowercase SHA-256"}
  ]
}
```

Compute a record hash using `shasum -a 256 <actual-file>`. The checker rejects
missing/empty/tampered evidence, symlinked paths, paths outside the evidence
directory, inconsistent platform data, future timestamps, duplicate/missing
checks and incomplete records. `translated` must be true for Rosetta and false
for native Intel/arm64 records. Never clear the pending-operation marker merely
to get a passing test.

## Repository and environment settings

Read-only API inspection confirmed main is unprotected, no tag rulesets exist,
and `release-signing` has no approval rules or ref policy. The repository has only
one collaborator, SeanPVera. The connected integration reports repository admin
status but denied protection writes and secret-name reads with HTTP 403,
`Resource not accessible by integration`. No protection or secret was changed.

Reviewed baseline payloads are in `.github/release-protections/`:

- `main.json`: require the seven observed GitHub Actions checks, strict branch
  freshness, admin enforcement, conversation resolution, no force push/deletion.
  `Universal DMG (macOS)` is intentionally not a required branch check because
  it only runs in the main/manual packaging workflow; the PR packaging job is.
- `version-tags.json`: prevent updating/deleting `v*` tags without exemptions.
- `release-signing.json`: enable explicit branch/tag restrictions; follow by
  allowing branch `main` for the existing manual build workflow and tags `v*`
  for publication, using `allow-main.json` and `allow-version-tags.json`. Other
  branch refs must not receive signing credentials.

These are baseline policies, **not completed independent-review protection**.
They do not select or invite another person. Before applying, re-read the current
settings and preserve any stronger protections added since this snapshot. Use
the owner's authenticated GitHub session/CLI to apply the settings, then choose
an eligible independent code/release reviewer and require their approval. Do not
disable self-review prevention or substitute the initiator for an independent
reviewer simply to unblock a release.

Useful owner settings pages:

- [Branch settings](https://github.com/SeanPVera/1132-fixer/settings/branches)
- [Tag rulesets](https://github.com/SeanPVera/1132-fixer/settings/rules)
- [Release environment](https://github.com/SeanPVera/1132-fixer/settings/environments)
- [Actions secrets](https://github.com/SeanPVera/1132-fixer/settings/secrets/actions)

## Credentials and final artifact

Enter credentials directly into `release-signing` environment secrets, never in
chat, source files or logs: `APPLE_CERTIFICATE` (base64 Developer ID Application
.p12), `APPLE_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_PASSWORD` (app-specific),
`APPLE_TEAM_ID`, `FIXER_BUG_REPORT_ENDPOINT` and `FIXER_BUG_REPORT_TOKEN`. All seven
are required before the signing build. The public app token is a write-only,
low-trust report credential, not an authentication boundary.

Only after native acceptance and owner protections pass, authorize production
signing/notarization and verify the exact candidate. Existing mounted-DMG checks
still require both slices, resource/runtime lookup, entitlements, version,
Developer ID signatures, stapled notarization and cleanup. Publishing or creating
a release tag is the final step, after those observations. No release tag has
been created by this work.

For a continuation handoff, use [CONTINUE_RELEASE.txt](CONTINUE_RELEASE.txt).
