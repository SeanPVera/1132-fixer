# 1132 Fixer

## [Releases](https://github.com/SeanPVera/1132-fixer/releases)

No signed release is published at the moment, so there is nothing to download yet. Until one is, build the app from source as described in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Only use builds from this repository's Releases page.

## [Discuss on Telegram](https://t.me/Team1132Fixer)

<img src="Sources/1132Fixer/Resources/AppIcon.png" width="128" alt="1132 Fixer app icon">

![GitHub Release](https://img.shields.io/github/v/release/SeanPVera/1132-fixer?style=for-the-badge) ![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/SeanPVera/1132-fixer/total?style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-silicone-yellow?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-intel-purple?logo=apple&style=for-the-badge) ![Static Badge](https://img.shields.io/badge/mac-universal-green?logo=apple&style=for-the-badge)

## What it does

1132 Fixer has two buttons. Neither one asks for your administrator password.

- **Launch Zoom**: closes Zoom if it's running, then relaunches it inside a macOS sandbox that hides your Mac's hardware identifiers (serial number, hardware UUID, board ID and similar) from Zoom. Nothing is deleted.
- **Reset & Launch…**: after you confirm, closes Zoom, deletes Zoom's local data (`~/Library/Application Support/zoom.us`, its caches, preferences, saved window state and `zoom.us.log` files), then launches it in the sandbox. You will need to sign in to Zoom again. There is no backup and it cannot be undone.

Before closing or deleting anything, both buttons check that the app really is Zoom (signed by Zoom's Apple team, signing identifier `us.zoom.xos`) and that macOS accepts the sandbox profile. If either check fails, nothing is changed and Zoom is not launched outside the sandbox.

Zoom is found in `/Applications` or `~/Applications`.

### Things to know

- **Always open Zoom from 1132 Fixer.** Opening Zoom any other way runs it without the sandbox.
- The sandbox may not hide your network hardware (MAC) address from Zoom. On macOS 15 or later, set **Private Wi-Fi Address** to **Rotating** in System Settings > Wi-Fi > Details.
- The sandbox blocks specific things rather than everything; see [SECURITY.md](SECURITY.md). It does not guarantee that error 1132 is resolved.
- macOS will ask once for camera and microphone access for 1132 Fixer, because Zoom runs inside it.

## License and Risk

This project is licensed under the terms in `LICENSE`.

Attribution is required: any copy, fork, or derivative of this project must
give clear and prominent credit to the original project, **1132 Fixer**, with
the original-project link required by the license, <https://github.com/1132-Fixer/macos>. Releases for this checkout are published at <https://github.com/SeanPVera/1132-fixer>. You may
not claim the original work as your own. See `LICENSE` for the full terms.

The software is provided "as is" with no warranty. Installing and using it is
at your own risk, and users accept responsibility for any impact on their
systems, network connectivity, or data.
