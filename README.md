# 1132 Fixer

## [Download the latest release here](https://github.com/SeanPVera/1132-fixer/releases/latest)

## [Discuss on Telegram](https://t.me/Team1132Fixer)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/SeanPVera/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/SeanPVera/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## macOS Zoom diagnostic and repair app

- `Review repair…`: validates the signed Zoom bundle and sandbox profile, shows every planned change for confirmation, closes Zoom, creates a recovery backup, handles the active network, clears Zoom local data/cache/preferences/log state, requests admin access to flush system DNS caches, stops Zoom's updaters for the current login session, then launches Zoom in the required sandbox mode with camera/microphone access preserved.
- `Preview steps`: checks compatibility, the Zoom signature, sandbox profile, backup capacity, media permissions, and network support without modifying the system.
- `Report a bug…`: opens a small form for optional email + message, then sends metadata plus an attached diagnostics file to the bug report API. The form lists exactly what the attachment contains, and `Export diagnostics…` in the bottom bar shows you the file itself. Reports are sent to the project's server over HTTPS only (the app refuses other schemes and does not follow redirects), and the diagnostics attachment is capped at 1 MiB (essential metadata and the newest activity are kept; home paths and MAC addresses are sanitized).

### Network identity and launch protection

- **macOS 13**: attempts a legacy MAC change on the active Wi-Fi or Ethernet interface, reconnects, and checks the observed address. Driver support varies.
- **macOS 14 or later**: no verified automatic identity mechanism is used. macOS 15+ offers **Off**, **Fixed**, and **Rotating** Private Wi-Fi Address settings in System Settings > Wi-Fi. The app cannot verify or configure these modes; reconnecting does not guarantee an immediate new address.
- A VPN default route prevents the network change. Other repair steps can continue with a recorded warning.

**Launch in sandbox** closes your running Zoom and launches the verified app in the required sandbox without a backup, reset, network change, or administrator DNS operation. Starting normal Zoom separately bypasses this launcher's protection. The profile denies selected identity and private-data access while preserving your existing home and login keychain; it does not fully isolate Zoom or guarantee that error 1132 is resolved.

### Backups

Before changing the network or clearing Zoom's local state, the app copies Zoom's state to `~/Library/Application Support/1132Fixer/Backups/`. Backups are readable only by your user account, use unique snapshot folders, and are cleaned up if a copy fails. The newest five snapshots are retained subject to a 2 GB aggregate cap; the newest snapshot is always preserved. After a run, **Reveal Backup** opens the recovery snapshot in Finder. Logs are permanently removed and are excluded from these backups. If the backup fails, repair stops before any network or Zoom-data changes. If reset fails, Zoom is not launched; earlier network/DNS changes may remain and no rollback is implied. If administrator completion is unknown, further repair and launch actions stay blocked until a Mac restart establishes settlement.

Before making changes and again before launch, the app verifies that the app is `zoom.us.app` and is signed by Zoom's Apple team. It also compiles the exact sandbox profile up front. Either failure blocks the repair rather than falling back to an unsandboxed launch.

## Updates

On launch, the app checks the GitHub Releases `latest` endpoint and prompts if a newer version is available.

## License and Risk

This project is licensed under the terms in `LICENSE`.

Attribution is required: any copy, fork, or derivative of this project must
give clear and prominent credit to the original project, **1132 Fixer**, with
the original-project link required by the license, <https://github.com/1132-Fixer/macos>. Releases and update checks for this checkout use <https://github.com/SeanPVera/1132-fixer>. You may
not claim the original work as your own. See `LICENSE` for the full terms.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
