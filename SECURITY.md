# Security Policy

## Supported Versions

Only the **latest release** of 1132 Fixer receives security updates.

Users are strongly encouraged to always download the newest version from the official releases page.

| Version | Supported |
| ------- | --------- |
| Latest  | ✅ |
| Older versions | ❌ |

Security fixes will be released as soon as possible in a new version.

## Known Design Limits

### The bug report token is not a secret

Releases embed a bearer token (`FIXER_BUG_REPORT_TOKEN`) into the app bundle at
build time. Anyone who downloads a release can read that value straight out of
`Contents/Resources/`, so it does **not** authenticate anything — it only
identifies the client build.

The bug report endpoint must therefore treat every caller as untrusted: rate
limiting and abuse controls belong on the server, and the token must not grant
any capability beyond submitting a report. Rotating it invalidates older app
versions but never makes the value confidential.

Please do not file this as a vulnerability; it is a known property of shipping a
client-side credential.

### The Zoom sandbox profile is a denylist, not a deny-by-default sandbox

Zoom is launched through `sandbox-exec` with a profile whose base is
`(allow default)`. Zoom is closed source and spawns its own capture helpers, so a
`(deny default)` profile could not be kept working across Zoom and macOS updates
— and because sandbox mode is the app's only launch path, a single missing allow
rule would leave users unable to start Zoom at all.

The profile therefore denies specific things rather than permitting specific
things. It closes the channels that expose stable hardware identity (IOKit
platform properties, the unique `sysctl` identifiers, the command-line tools that
report them, and the plists recording network identity), and it blocks the
sandboxed session from reading private user data such as SSH keys, keychains,
browser profiles, and other accounts' home directories.

Anything not named in the profile is still allowed. Treat it as identity and
privacy containment for the Zoom session, not as a general confinement boundary
for untrusted code.

### Elevated privileges

The app requests administrator access for two operations only: flushing system
DNS caches, and changing network interface settings on the macOS versions where
that still works. Clearing Zoom's local state runs unprivileged, since every path
it touches is inside the user's own home directory.

## Reporting a Vulnerability

If you discover a security vulnerability in **1132 Fixer**, please report it responsibly.

Do **not** open a public GitHub issue for security vulnerabilities.

Instead, open a **private security advisory** on GitHub

Please include:

- A description of the vulnerability
- Steps to reproduce the issue
- The affected version
- Any proof-of-concept or screenshots (if applicable)

## Response Process

After a vulnerability report is received:

1. You will receive an acknowledgement within **72 hours**
2. The issue will be investigated and reproduced
3. If confirmed, a fix will be prepared and released
4. Credit may be given to the reporter if they wish

Critical vulnerabilities will be prioritized and fixed as quickly as possible.

## Responsible Disclosure

Please allow reasonable time for the issue to be resolved before publicly disclosing it.

Public disclosure before a fix is available may put users at risk.
