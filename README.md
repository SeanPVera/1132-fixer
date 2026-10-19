# 1132 Fixer

## [Download the latest release here](https://github.com/1132-Fixer/macos/releases/latest)

## [Discuss on Telegram](https://t.me/Team1132Fixer)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/1132-Fixer/macos?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/1132-Fixer/macos/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## macOS Zoom diagnostic and repair app

- `Start Zoom Repair`: validates the signed Zoom bundle and sandbox profile, shows every planned change for confirmation, closes Zoom, creates a recovery backup, handles the active network, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, stops Zoom's updaters for the current login session, then launches Zoom in the required sandbox mode with camera/microphone access preserved.
- `Dry Run`: checks compatibility, the Zoom signature, sandbox profile, backup capacity, media permissions, and network support without modifying the system.
- `Report a Bug`: opens a small form for optional email + message, then sends metadata plus an attached diagnostics file to the bug report API. The form lists exactly what the attachment contains, and `Export Diagnostics` in the app header shows you the file itself. Reports are sent to the project's server over HTTPS only (the app refuses other schemes and does not follow redirects), and the diagnostics attachment is capped at 1 MB (the newest log lines are kept).

### What Start Zoom does about network identity

This depends on your Mac, and the app tells you which case applies before you run it:

- **macOS 13**: the active Wi-Fi or Ethernet interface is MAC-spoofed and reconnected.
- **Apple Silicon on macOS 14 or later, over Wi-Fi**: the legacy method no longer works, so the app switches the network to a rotating Private Wi-Fi Address and cycles Wi-Fi to pick up a new one.
- **Anything else on macOS 14 or later**: no network identity change is possible; the step is skipped with a warning and the rest of the workflow still runs.

If a VPN is carrying your default route, the network step is skipped with a warning and the remaining steps still run. Turn the VPN off first if you want that step to do anything.

The last two cases mean Zoom may still see the same network identity, so error 1132 can persist.

### Backups

Before changing the network or clearing Zoom's local state, the app copies Zoom's state to `~/Library/Application Support/1132Fixer/Backups/`. Backups are readable only by your user account, use unique snapshot folders, and are cleaned up if a copy fails. The newest five snapshots are retained subject to a 2 GB aggregate cap; the newest snapshot is always preserved. After a run, **Reveal Backup** opens the recovery snapshot in Finder. If the backup fails, Start Zoom Repair stops before any network or Zoom-data changes.

Before making changes and again before launch, the app verifies that the app is `zoom.us.app` and is signed by Zoom's Apple team. It also compiles the exact sandbox profile up front. Either failure blocks the repair rather than falling back to an unsandboxed launch.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## License and Risk

This project is licensed under the terms in `LICENSE`.

Attribution is required: any copy, fork, or derivative of this project must
give clear and prominent credit to the original project, **1132 Fixer**, with
a working link to <https://github.com/1132-Fixer/macos>. You may
not claim the original work as your own. See `LICENSE` for the full terms.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
