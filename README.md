# 1132 Fixer

## [Releases](https://github.com/SeanPVera/1132-fixer/releases)

No signed release is published at the moment, so there is nothing to download yet. Until one is, build the app from source as described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Only use builds from this repository's Releases page.

## [Discuss on Telegram](https://t.me/Team1132Fixer)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/SeanPVera/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/SeanPVera/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## macOS Zoom diagnostic and repair app

- `Review repair…`: validates the signed Zoom bundle and sandbox profile, shows every planned change for confirmation, closes Zoom, creates a recovery backup, handles the active network, requests admin access to flush system DNS caches, then clears Zoom local data/cache/preferences/log state (only after every administrator step finished with a known result), stops Zoom's updaters for the current login session, then launches Zoom in the required sandbox mode with camera/microphone access preserved.
- `Preview steps`: checks compatibility, the Zoom signature, sandbox profile, backup capacity, media permissions, and network support without modifying the system.
- `Report a bug…`: opens a small form for optional email + message, then sends metadata plus an attached diagnostics file to the bug report API. The form lists exactly what the attachment contains, and `Export diagnostics…` in the bottom bar shows you the file itself. Reports are sent only to the endpoint configured for that build, over HTTPS only (the app refuses other schemes and does not follow redirects); a build without a configured endpoint cannot send reports and there is no built-in fallback server. The diagnostics attachment is capped at 1 MiB (essential metadata and the newest activity are kept; home paths, other accounts' folders, MAC addresses and IPv4 addresses are sanitized). **Copy logs** uses the same sanitizer.

### Network identity and launch protection

- **macOS 13**: attempts a legacy MAC change on the active Wi-Fi or Ethernet interface, reconnects, and checks the observed address. Driver support varies.
- **macOS 14 or later**: no verified automatic identity mechanism is used. macOS 15+ offers **Off**, **Fixed**, and **Rotating** Private Wi-Fi Address settings in System Settings > Wi-Fi. The app cannot verify or configure these modes; reconnecting does not guarantee an immediate new address.
- A VPN default route prevents the network change. Other repair steps can continue with a recorded warning.

**Launch in sandbox** closes your running Zoom and launches the verified app in the required sandbox without a backup, reset, network change, or administrator DNS operation. Starting normal Zoom separately bypasses this launcher's protection. The profile denies selected identity and private-data access while preserving your existing home and login keychain; it does not fully isolate Zoom or guarantee that error 1132 is resolved.

### Backups

Before changing the network or clearing Zoom's local state, the app copies Zoom's state to `~/Library/Application Support/1132Fixer/Backups/`. Backups are readable only by your user account, use unique snapshot folders, and are cleaned up if a copy fails. The newest five snapshots are retained subject to a 2 GB aggregate cap; the newest snapshot is always preserved. After a run, **Reveal Backup** opens the recovery snapshot in Finder. Zoom's own logs (`~/Library/Logs/zoom.us.log` and its numbered rotations) are included in the backup's `Logs/` folder before they are removed; other files in `~/Library/Logs` are left alone. Before deleting anything, the reset checks that every listed path can be removed and stops without deleting if one cannot. If the backup fails, repair stops before any network or Zoom-data changes. If reset fails, Zoom is not launched; earlier network/DNS changes may remain and no rollback is implied. If administrator completion is unknown, further repair and launch actions stay blocked until a Mac restart establishes settlement.

Before making changes and again before launch, the app verifies that the app is `zoom.us.app`, is signed by Zoom's Apple team, and carries Zoom's `us.zoom.xos` signing identifier. The repair you confirm is bound to the Zoom location you reviewed; if it changes, nothing is started. It also compiles the exact sandbox profile up front. Either failure blocks the repair rather than falling back to an unsandboxed launch.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available. The check talks only to `api.github.com` (other redirects are refused), reads at most 256 KB, and opens a release link the app builds itself from the validated version tag. While no release is published, no update prompt appears.

## License and Risk

This project is licensed under the terms in `LICENSE`.

Attribution is required: any copy, fork, or derivative of this project must
give clear and prominent credit to the original project, **1132 Fixer**, with
the original-project link required by the license, <https://github.com/1132-Fixer/macos>. Releases and update checks for this checkout use <https://github.com/SeanPVera/1132-fixer>. You may
not claim the original work as your own. See `LICENSE` for the full terms.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
