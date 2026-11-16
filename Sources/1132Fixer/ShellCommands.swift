import Foundation
import Darwin

/// Finds the Zoom app. Only the two standard install locations are checked; the
/// resolved binary is always run through `sandbox-exec`.
enum ZoomLocation {
    static let candidateAppPaths = [
        ShellCommands.defaultZoomAppPath,
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications/zoom.us.app"),
    ]

    /// The first standard location that contains the Zoom executable, else `/Applications`.
    static var appPath: String {
        candidateAppPaths.first {
            FileManager.default.isExecutableFile(atPath: ShellCommands.zoomBinaryPath(forAppPath: $0))
        } ?? ShellCommands.defaultZoomAppPath
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: ShellCommands.zoomBinaryPath(forAppPath: appPath))
    }
}

/// The Zoom state the reset clears, relative to the user's home directory.
enum ZoomStateScope {
    static let statePaths = [
        "Library/Application Support/zoom.us",
        "Library/Caches/us.zoom.xos",
        "Library/Preferences/us.zoom.xos.plist",
        "Library/Saved Application State/us.zoom.xos.savedState",
    ]
    /// Exact log naming contract: `Library/Logs/zoom.us.log` and its numbered rotations
    /// (`zoom.us.log.1`, `zoom.us.log.2`, ...). Nothing else in `Library/Logs` is touched.
    static let logsRelativeDirectory = "Library/Logs"
}

enum ShellCommands {
    static let bashPath = "/bin/bash"
    static let defaultZoomAppPath = "/Applications/zoom.us.app"


    static func currentUserProcessArguments(name: String) -> [String] {
        ["-u", String(getuid()), "-x", NSRegularExpression.escapedPattern(for: name)]
    }

    static func makeZoomRunningCheckCommand() -> String {
        "/usr/bin/pgrep " + currentUserProcessArguments(name: "zoom.us").map(shellSingleQuote).joined(separator: " ")
            + " >/dev/null 2>&1 && echo running || echo stopped"
    }

    /// Derives the Zoom executable path from a `zoom.us.app` bundle path.
    static func zoomBinaryPath(forAppPath appPath: String) -> String {
        (appPath as NSString).appendingPathComponent("Contents/MacOS/zoom.us")
    }

    /// Binary path for the default install location. A user-selected location is
    /// resolved through `ZoomLocation` and passed explicitly where it matters.
    static let zoomBinaryPath = "/Applications/zoom.us.app/Contents/MacOS/zoom.us"

    // MARK: - Shell Quoting

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Quotes a value for use as a sandbox profile (SBPL) string literal.
    /// Backslash and double quote are the only characters SBPL treats specially
    /// inside a string; an unescaped one would end the literal early and change
    /// which paths a rule matches.
    static func sandboxStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Close and Reset Zoom

    /// Closes Zoom and its capture helpers for the current user only, and exits 1 if any
    /// of them is still running afterwards so nothing is deleted under a live Zoom.
    static let stopZoom = #"""
    uid="$(/usr/bin/id -u)"
    zoom_processes=("zoom[.]us" "caphost" "CptHost")
    if /usr/bin/pgrep -u "$uid" -x "zoom[.]us" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "CptHost" >/dev/null 2>&1; then
      for proc in "${zoom_processes[@]}"; do
        /usr/bin/pkill -u "$uid" -x "$proc" 2>/dev/null || true
      done
      echo "Zoom was running and has been closed."
      for i in {1..10}; do
        if ! /usr/bin/pgrep -u "$uid" -x "zoom[.]us" >/dev/null 2>&1 && ! /usr/bin/pgrep -u "$uid" -x "caphost" >/dev/null 2>&1 && ! /usr/bin/pgrep -u "$uid" -x "CptHost" >/dev/null 2>&1; then
          break
        fi
        /bin/sleep 0.5
      done
      if /usr/bin/pgrep -u "$uid" -x "zoom[.]us" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "CptHost" >/dev/null 2>&1; then
        for proc in "${zoom_processes[@]}"; do
          /usr/bin/pkill -KILL -u "$uid" -x "$proc" 2>/dev/null || true
        done
        /bin/sleep 1
      fi
    fi

    if /usr/bin/pgrep -u "$uid" -x "zoom[.]us" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -u "$uid" -x "CptHost" >/dev/null 2>&1; then
      echo "Zoom or one of its capture helpers is still running; refusing to modify Zoom data." >&2
      exit 1
    fi
    """#

    /// Whether `path` is acceptable as the base for the `rm -rf` of Zoom's state: non-empty,
    /// absolute, and not the filesystem root. (The generated script re-checks this, and that
    /// the directory exists, before deleting anything.)
    static func isSafeHomeDirectory(_ path: String) -> Bool {
        normalizedSafeHomeDirectory(path) != nil
    }

    /// Returns a lexical, absolute home path only when dot components cannot normalize it
    /// to another location. The physical path is checked separately immediately before use.
    static func normalizedSafeHomeDirectory(_ path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.hasPrefix("/"), trimmed != "/" else { return nil }
        let standardized = (trimmed as NSString).standardizingPath
        guard standardized == trimmed, standardized != "/" else { return nil }
        return standardized
    }

    /// Prints, one per line, the Zoom log files covered by the exact naming contract in
    /// `ZoomStateScope` (`zoom.us.log` and `zoom.us.log.<digits>`) that are regular files
    /// or symbolic links (a link is removed, never followed).
    /// Matching names of any other type are reported on stderr and left alone.
    static let zoomLogCandidatesFunction = #"""
    __1132_zoom_log_candidates() {
      __1132_logs_dir="$1"
      [ -d "$__1132_logs_dir" ] || return 0
      for __1132_log in "$__1132_logs_dir"/zoom.us.log "$__1132_logs_dir"/zoom.us.log.*; do
        [ -e "$__1132_log" ] || [ -L "$__1132_log" ] || continue
        __1132_log_name="${__1132_log##*/}"
        case "$__1132_log_name" in
          zoom.us.log) ;;
          zoom.us.log.*)
            __1132_log_suffix="${__1132_log_name#zoom.us.log.}"
            case "$__1132_log_suffix" in
              ''|*[!0-9]*) continue ;;
            esac
            ;;
          *) continue ;;
        esac
        if [ -L "$__1132_log" ] || [ -f "$__1132_log" ]; then
          printf '%s\n' "$__1132_log"
        else
          printf 'Note: leaving %s in place; it is not a regular log file.\n' "$__1132_log" >&2
        fi
      done
    }
    """#

    /// Clears Zoom's local state. Runs as the current user (no administrator privileges):
    /// every path is inside the user's own home directory, and running `rm -rf` and
    /// `defaults delete` as root could leave root-owned files in `~/Library`.
    ///
    /// The cleanup set is decided and checked before anything is deleted: the four
    /// Zoom state paths plus the contract-named log files. If any of them cannot be
    /// removed (an unwritable parent, or a directory inside the state that this user
    /// cannot empty), the script refuses with "Nothing was deleted" instead of deleting
    /// part of the state and then failing.
    ///
    /// `deletePreferencesDomain` exists for disposable fixtures only: `defaults` talks to
    /// the per-user preferences daemon, which does not honor the `HOME` override.
    static func makeResetZoomDataCommand(homeDirectory: String, deletePreferencesDomain: Bool = true) -> String {
        let home = shellSingleQuote(homeDirectory)
        let preferencesStep = deletePreferencesDomain
            ? #"HOME="$home" /usr/bin/defaults delete us.zoom.xos >/dev/null 2>&1 || true"#
            : ": # preferences-domain deletion disabled for this fixture"
        return """
        home=\(home)
        while [ "${home%/}" != "$home" ] && [ -n "${home%/}" ]; do home="${home%/}"; done
        case "$home" in
          /*) ;;
          *)
            echo "Reset Zoom data: home directory '$home' is not an absolute path; refusing to delete anything." >&2
            exit 1
            ;;
        esac
        if [ "$home" = "/" ] || [ "${home%/}" = "" ] || [ ! -d "$home" ]; then
          echo "Reset Zoom data: home directory '$home' is not a usable directory; refusing to delete anything." >&2
          exit 1
        fi
        home_physical="$(cd -P "$home" 2>/dev/null && /bin/pwd -P)" || exit 1
        if [ "$home_physical" = "/" ]; then
          echo "Reset Zoom data: home directory resolves to the filesystem root; refusing to delete anything." >&2
          exit 1
        fi
        for parent_dir in \\
          "$home_physical/Library" \\
          "$home_physical/Library/Application Support" \\
          "$home_physical/Library/Caches" \\
          "$home_physical/Library/Preferences" \\
          "$home_physical/Library/Logs" \\
          "$home_physical/Library/Saved Application State"; do
          if [ -L "$parent_dir" ]; then
            echo "Reset Zoom data: refusing to traverse symbolic link at '$parent_dir'." >&2
            exit 1
          fi
        done
        \(zoomLogCandidatesFunction)
        uid="$(/usr/bin/id -u)"

        zoom_data="$home_physical/\(ZoomStateScope.statePaths[0])"
        zoom_cache="$home_physical/\(ZoomStateScope.statePaths[1])"
        zoom_prefs="$home_physical/\(ZoomStateScope.statePaths[2])"
        zoom_saved_state="$home_physical/\(ZoomStateScope.statePaths[3])"
        zoom_logs_dir="$home_physical/\(ZoomStateScope.logsRelativeDirectory)"

        # Preflight: refuse before deleting anything when part of the set cannot be removed.
        preflight_failed=0
        refuse_reset() {
          echo "Reset Zoom data: $1 Nothing was deleted." >&2
          preflight_failed=1
        }
        for path in "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"; do
          [ -e "$path" ] || [ -L "$path" ] || continue
          parent="${path%/*}"
          if [ ! -w "$parent" ] || [ ! -x "$parent" ]; then
            refuse_reset "'$parent' is not writable by this user."
            continue
          fi
          if [ -d "$path" ] && [ ! -L "$path" ]; then
            if ! blocked="$(/usr/bin/find "$path" -type d \\( ! -user "$uid" -o ! -perm -u=rwx \\) -print -quit 2>/dev/null)"; then
              refuse_reset "'$path' could not be fully inspected."
            elif [ -n "$blocked" ]; then
              refuse_reset "'$blocked' cannot be emptied by this user."
            fi
          fi
        done
        if ! log_targets="$(__1132_zoom_log_candidates "$zoom_logs_dir")"; then
          refuse_reset "Zoom log files could not be listed."
        fi
        if [ -n "$log_targets" ] && { [ ! -w "$zoom_logs_dir" ] || [ ! -x "$zoom_logs_dir" ]; }; then
          refuse_reset "'$zoom_logs_dir' is not writable by this user."
        fi
        if [ "$preflight_failed" -ne 0 ]; then
          exit 1
        fi

        reset_failed=0
        /bin/rm -rf "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state" || reset_failed=1
        if [ -n "$log_targets" ]; then
          while IFS= read -r log_path; do
            /bin/rm -f "$log_path" || reset_failed=1
          done <<< "$log_targets"
        fi
        \(preferencesStep)

        remaining="$reset_failed"
        for path in "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"; do
          if [ -e "$path" ] || [ -L "$path" ]; then
            echo "Warning: Could not remove $path" >&2
            remaining=1
          fi
        done
        leftover_logs="$(__1132_zoom_log_candidates "$zoom_logs_dir" 2>/dev/null)"
        if [ -n "$leftover_logs" ]; then
          echo "Warning: Could not remove Zoom log files: $leftover_logs" >&2
          remaining=1
        fi

        exit "$remaining"
        """
    }

    // MARK: - Launch Zoom

    // Zoom must stay inside sandbox-exec for this app. Do not replace this
    // profile-backed launch with /usr/bin/open or any other normal Zoom launch.

    /// Sandbox profile for the running user.
    static var zoomSandboxProfile: String {
        get throws { try makeZoomSandboxProfile(homeDirectory: NSHomeDirectory()) }
    }

    /// Home-relative directories Zoom is denied read access to. Zoom needs none of
    /// them, and macOS treats 1132 Fixer as the TCC *responsible* process for the
    /// sandboxed session, so without these rules Zoom would inherit this app's
    /// standing when it reaches for TCC-protected data.
    ///
    /// `Application Support/1132Fixer` may still hold backups of Zoom's previous local
    /// state made by earlier versions of this app — readable, that is a copy of the very
    /// identity the reset just cleared.
    private static let deniedHomeReadSubpaths = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".docker",
        ".config",
        "Library/Containers",
        "Library/Cookies",
        "Library/Mail",
        "Library/Messages",
        "Library/Safari",
        "Library/Calendars",
        "Library/IdentityServices",
        "Library/Application Support/1132Fixer",
        "Library/Application Support/AddressBook",
        "Library/Application Support/BraveSoftware",
        "Library/Application Support/Firefox",
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Microsoft Edge",
        "Library/Application Support/MobileSync",
        "Library/Application Support/com.apple.sharedfilelist",
        "Pictures/Photos Library.photoslibrary"
    ]

    private static let deniedHomeReadLiterals = [
        ".netrc",
        ".bash_history",
        ".zsh_history"
    ]

    /// Home-relative directories Zoom is denied write access to. `Library/LaunchAgents`
    /// stops the sandboxed session from installing login agents. This lasts only as long
    /// as the sandboxed process: existing agent files are untouched.
    ///
    /// Credential stores that are read-denied are write-denied too (F-013): `.kube`,
    /// `.docker` and `.netrc` hold cluster, registry and host credentials that Zoom never
    /// needs to read or write. Each was reviewed individually; history files are
    /// read-denied for privacy but are not credentials, so they are not added here.
    private static let deniedHomeWriteSubpaths = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".docker",
        ".config",
        "Applications",
        "Library/LaunchAgents",
        "Library/Application Support/1132Fixer"
    ]

    private static let deniedHomeWriteLiterals = [
        ".netrc",
        ".zshrc",
        ".zprofile",
        ".zshenv",
        ".zlogin",
        ".bashrc",
        ".bash_profile",
        ".profile",
        ".gitconfig"
    ]

    /// Returns an absolute home path with trailing slashes trimmed, or `nil` when the
    /// value cannot anchor a `subpath` rule. `/` is rejected on purpose: anchoring
    /// these rules at the filesystem root would deny Zoom most of the disk.
    static func normalizedSandboxHome(_ homeDirectory: String) -> String? {
        var path = homeDirectory
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard standardized == path, standardized != "/" else { return nil }
        return standardized
    }

    /// Builds the sandbox profile Zoom runs under.
    ///
    /// The base stays `(allow default)`. Zoom is closed source, spawns its own capture
    /// helpers, and this app has no non-sandbox launch path to fall back on, so a
    /// `(deny default)` profile could not be kept working across Zoom and macOS updates
    /// — a single missing allow rule would leave users unable to start Zoom at all.
    /// Everything below is therefore a denylist, and it is written to be exhaustive
    /// about the two things worth containing:
    ///
    /// 1. **Stable hardware identity.** Error 1132 is a device-level ban, so every
    ///    channel that lets Zoom re-derive the same machine fingerprint is closed:
    ///    IOKit properties, the `sysctl` identifiers, the command-line tools that
    ///    report them, and the on-disk files that record network identity.
    /// 2. **Private user data.** See `deniedHomeReadSubpaths`. Keychain files are
    ///    deliberately excluded: the Security framework reads the user's database
    ///    and writes sibling lock/temporary files in the client process. Blocking
    ///    those operations breaks Zoom's keychain access at the final launch step,
    ///    even with SecurityServer/securityd Mach lookups allowed. Keychain item
    ///    access remains subject to macOS unlock requirements and access controls.
    ///
    /// SBPL resolves the *last* matching rule, so the denies below override the blanket
    /// allows above them, and the home allow-back overrides the `/Users` deny. Rule
    /// order in this profile is load-bearing.
    static func makeZoomSandboxProfile(homeDirectory: String) throws -> String {
        var profile = zoomSandboxProfilePrefix

        guard let home = normalizedSandboxHome(homeDirectory), !home.contains("\0"),
              home.rangeOfCharacter(from: .newlines) == nil else {
            throw AppError.general("A safe absolute home directory is required; refusing to omit sandbox privacy restrictions.")
        }

        let homeLiteral = sandboxStringLiteral(home)
        let readSubpaths = deniedHomeReadSubpaths
            .map { "    (subpath \(sandboxStringLiteral("\(home)/\($0)")))" }
            .joined(separator: "\n")
        let readLiterals = deniedHomeReadLiterals
            .map { "    (literal \(sandboxStringLiteral("\(home)/\($0)")))" }
            .joined(separator: "\n")
        let writeSubpaths = deniedHomeWriteSubpaths
            .map { "    (subpath \(sandboxStringLiteral("\(home)/\($0)")))" }
            .joined(separator: "\n")
        let writeLiterals = deniedHomeWriteLiterals
            .map { "    (literal \(sandboxStringLiteral("\(home)/\($0)")))" }
            .joined(separator: "\n")

        profile += """


        ; Other users' files. Allowed back for this user's own home immediately
        ; below, so the deny only covers accounts Zoom has no business reading.
        (deny file-read* (subpath "/Users"))
        (allow file-read* (subpath \(homeLiteral)))
        (allow file-read* (subpath "/Users/Shared"))

        ; Private data inside this user's own home.
        (deny file-read*
        \(readSubpaths)
        \(readLiterals)
        )

        (deny file-write*
        \(writeSubpaths)
        \(writeLiterals)
        )
        """

        return profile
    }

    private static let zoomSandboxProfilePrefix = """
    (version 1)
    (allow default)

    ; Camera and microphone access must remain explicit because Zoom runs under
    ; sandbox-exec for the full session, including helper-based video capture.
    ; These allows are redundant while the default is `allow`; they stay because
    ; they record the exact set the capture path needs, and the denies further
    ; down must never grow to cover any of it.
    (allow device-camera)
    (allow device-microphone)
    (allow iokit-get-properties)
    (allow iokit-open
        (iokit-user-client-class "AppleAVE2UserClient")
        (iokit-user-client-class "AppleH13CamInUserClient")
        (iokit-user-client-class "AppleUSBHostFrameworkInterfaceClient")
        (iokit-user-client-class "H11ANEInDirectPathClient")
        (iokit-user-client-class "H1xANELoadBalancerClient")
        (iokit-user-client-class "H1xANELoadBalancerDirectPathClient")
        (iokit-user-client-class "IOSurfaceRootUserClient")
        (iokit-user-client-class "IOUSBDeviceUserClientV2")
        (iokit-user-client-class "IOUSBInterfaceUserClientV2")
        (iokit-user-client-class "IOUSBInterfaceUserClientV3")
        (iokit-user-client-class "IOUserUserClient")
        (iokit-user-client-class "RootDomainUserClient")
    )
    (allow mach-lookup
        (global-name "com.apple.SecurityServer")
        (global-name "com.apple.applecamerad")
        (global-name "com.apple.appleh13camerad")
        (global-name "com.apple.appleh16camerad")
        (global-name "com.apple.airplay.endpoint.xpc")
        (global-name "com.apple.audio.AudioComponentRegistrar")
        (global-name "com.apple.audio.AudioSession")
        (global-name "com.apple.audio.audiohald")
        (global-name "com.apple.audio.coreaudiod")
        (global-name "com.apple.cmio.AVCAssistant")
        (global-name "com.apple.cmio.VDCAssistant")
        (global-name "com.apple.cmio.AppleCameraAssistant")
        (global-name "com.apple.cmio.IIDCVideoAssistant")
        (global-name "com.apple.cmio.iOSScreenCaptureAssistant")
        (global-name "com.apple.cmio.registerassistantservice")
        (global-name "com.apple.cmio.registerassistantservice.system-extensions")
        (global-name "com.apple.cmio.system-extensions")
        (global-name "com.apple.coreservices.launchservicesd")
        (global-name "com.apple.coremedia.endpoint.xpc")
        (global-name "com.apple.coremedia.virtualdisplaycg")
        (global-name "com.apple.lsd.modifydb")
        (global-name "com.apple.mediaexperience.endpoint.xpc")
        (global-name "com.apple.pluginkit.pkd")
        (global-name "com.apple.rtcreportingd")
        (global-name "com.apple.runningboard")
        (global-name "com.apple.securityd.xpc")
        (global-name "com.apple.tccd")
        (global-name "com.apple.tccd.system")
        (global-name "com.apple.videoconference.camera")
        (global-name "com.apple.windowserver.active")
    )

    ; Stable hardware identity, which is what a 1132 device ban keys on.
    ;
    ; Every key below lives on the platform-expert or device-tree node, so denying
    ; it costs Zoom nothing. Generic keys that also appear on peripherals --
    ; "model", "manufacturer", "SerialNumber" -- are deliberately absent: an
    ; iokit-property filter matches on every registry entry, so denying those
    ; would break camera and USB device enumeration.
    (deny iokit-get-properties
        (iokit-property "IOPlatformSerialNumber")
        (iokit-property "IOPlatformUUID")
        (iokit-property "IOMACAddress")
        (iokit-property "board-id")
        (iokit-property "chip-id")
        (iokit-property "die-id")
        (iokit-property "local-mac-address")
        (iokit-property "mlb-serial-number")
        (iokit-property "model-number")
        (iokit-property "nvram-proxy-data")
        (iokit-property "platform-uuid")
        (iokit-property "region-info")
        (iokit-property "regulatory-model-number")
        (iokit-property "serial-number")
        (iokit-property "system-serial-number")
        (iokit-property "target-type")
        (iokit-property "unique-chip-id")
    )

    ; Per-machine sysctl identifiers. Low-entropy ones such as hw.model and
    ; machdep.cpu.brand_string stay readable: they are shared by millions of
    ; machines and Zoom uses them to pick codecs.
    (deny sysctl-read
        (sysctl-name "hw.serialnumber")
        (sysctl-name "hw.uuid")
        (sysctl-name "kern.uuid")
    )

    ; The command-line tools that report the same identifiers. Zoom has no reason
    ; to shell out to any of them, and the in-process equivalents are already
    ; denied above.
    (deny process-exec
        (literal "/bin/hostname")
        (literal "/sbin/ifconfig")
        (literal "/usr/bin/dscl")
        (literal "/usr/libexec/remotectl")
        (literal "/usr/sbin/arp")
        (literal "/usr/sbin/diskutil")
        (literal "/usr/sbin/ioreg")
        (literal "/usr/sbin/netstat")
        (literal "/usr/sbin/networksetup")
        (literal "/usr/sbin/nvram")
        (literal "/usr/sbin/scutil")
        (literal "/usr/sbin/sysctl")
        (literal "/usr/sbin/system_profiler")
    )

    ; On-disk records of network and machine identity. The airport and network
    ; identification plists are the strongest of these: they hold the history of
    ; every Wi-Fi network and router this Mac has joined.
    (deny file-read*
        (literal "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist")
        (literal "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist")
        (literal "/Library/Preferences/SystemConfiguration/com.apple.network.identification.plist")
        (literal "/Library/Preferences/SystemConfiguration/preferences.plist")
        (literal "/Library/Preferences/com.apple.Bluetooth.plist")
        (literal "/private/var/db/SystemKey")
        (subpath "/Library/Application Support/CrashReporter")
        (subpath "/private/var/db/ConfigurationProfiles")
        (subpath "/private/var/db/dslocal")
    )

    ; System keychains must remain readable for normal Keychain/trust operations.
    ; Keep system credential writes and persistence blocked.
    (deny file-read*
        (subpath "/private/etc/ssh")
    )
    (deny file-write*
        (subpath "/Library/Keychains")
        (subpath "/Library/LaunchAgents")
        (subpath "/Library/LaunchDaemons")
    )
    """

    static func makeLaunchZoomCommand() -> String {
        makeLaunchZoomCommand(zoomBinaryPath: zoomBinaryPath)
    }

    static func makeLaunchZoomCommand(
        zoomBinaryPath: String,
        homeDirectory: String = NSHomeDirectory(),
        verifiedAppPath: String? = nil
    ) -> String {
        makeLaunchZoomCommand(
            zoomBinaryPath: zoomBinaryPath,
            zoomBinaryExists: FileManager.default.fileExists(atPath: zoomBinaryPath),
            homeDirectory: homeDirectory,
            verifiedAppPath: verifiedAppPath
        )
    }

    static func makeLaunchZoomCommand(zoomBinaryExists: Bool) -> String {
        makeLaunchZoomCommand(
            zoomBinaryPath: zoomBinaryPath,
            zoomBinaryExists: zoomBinaryExists,
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Builds a non-mutating command that compiles the exact profile used for Zoom.
    /// Both actions run this before closing Zoom or deleting anything.
    static func makeSandboxProfileValidationCommand(
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        guard let profile = try? makeZoomSandboxProfile(homeDirectory: homeDirectory) else {
            return "echo 'Invalid home directory; required sandbox profile cannot be constructed.' >&2; exit 1"
        }
        let encodedProfile = Data(profile.utf8).base64EncodedString()
        return """
        set -u
        if [ ! -x /usr/bin/sandbox-exec ]; then
          echo "sandbox-exec is unavailable; Zoom cannot be launched in the required sandbox mode." >&2
          exit 1
        fi
        encoded_profile=\(shellSingleQuote(encodedProfile))
        tmp_dir="${TMPDIR:-/tmp}"
        profile_path="$(/usr/bin/mktemp "${tmp_dir%/}/1132fixer.zoom-sandbox-check.XXXXXX")" || exit 1
        cleanup() { /bin/rm -f "$profile_path"; }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        /bin/echo "$encoded_profile" | /usr/bin/base64 --decode > "$profile_path" || exit 1
        if ! profile_error="$(/usr/bin/sandbox-exec -f "$profile_path" /usr/bin/true 2>&1)"; then
          echo "macOS rejected the Zoom sandbox profile. Details: $profile_error" >&2
          exit 1
        fi
        echo "Sandbox profile validated."
        """
    }

    /// Builds the launch script that the caller hands to `/bin/bash -c`.
    ///
    /// The script must never wrap itself in another `/bin/bash -c '...'`: the single
    /// quotes produced by `shellSingleQuote` would close that wrapper's quoting, so the
    /// interpolated Zoom path would reach the outer shell unquoted. Interpolate paths
    /// only through `shellSingleQuote`, and reference them as `"$zoom_binary"`.
    static func makeLaunchZoomCommand(
        zoomBinaryPath: String,
        zoomBinaryExists: Bool,
        homeDirectory: String = NSHomeDirectory(),
        verifiedAppPath: String? = nil
    ) -> String {
        let quotedBinaryPath = shellSingleQuote(zoomBinaryPath)
        let appPath = verifiedAppPath ?? (zoomBinaryPath as NSString).deletingLastPathComponent.components(separatedBy: "/Contents/").first ?? ""
        let quotedAppPath = shellSingleQuote(appPath)

        guard zoomBinaryExists else {
            return """
            zoom_binary=\(quotedBinaryPath)
            echo "Launch mode: sandboxRequiredMissingBinary"
            echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at $zoom_binary. Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
            exit 1
            """
        }

        guard let profile = try? makeZoomSandboxProfile(homeDirectory: homeDirectory) else {
            return "echo 'Invalid home directory; required sandbox profile cannot be constructed.' >&2; exit 1"
        }
        let encodedProfile = Data(profile.utf8).base64EncodedString()
        return """
        set -u

        zoom_binary=\(quotedBinaryPath)
        encoded_profile=\(shellSingleQuote(encodedProfile))

        if [ ! -x /usr/bin/sandbox-exec ]; then
          echo "Error: sandbox-exec is unavailable, so Zoom cannot be launched in the required sandbox mode." >&2
          exit 1
        fi

        # The per-user TMPDIR (mode 0700) rather than /tmp, which every local
        # account can write to and list.
        tmp_dir="${TMPDIR:-/tmp}"
        profile_path="$(/usr/bin/mktemp "${tmp_dir%/}/1132fixer.zoom-sandbox.XXXXXX")" || exit 1

        cleanup() {
          /bin/rm -f "$profile_path"
        }

        tracked_sandbox_child_is_running() {
          # jobs tracks this shell's live child, so a reused numeric PID or another
          # user's/same-name Zoom cannot satisfy launch success.
          /bin/kill -0 "$sandbox_pid" 2>/dev/null || return 1
          /usr/bin/grep -qx "$sandbox_pid" < <(jobs -pr) || return 1
          child_uid="$(/bin/ps -p "$sandbox_pid" -o uid= | /usr/bin/tr -d ' ')"
          [ "$child_uid" = "$uid" ] || return 1
          child_command="$(/bin/ps -ww -p "$sandbox_pid" -o comm=)"
          [ "$child_command" = "$zoom_binary" ] || return 1
        }

        stop_zoom_processes() {
        \(stopZoom)
        }

        trap cleanup EXIT
        /bin/echo "$encoded_profile" | /usr/bin/base64 --decode > "$profile_path" || exit 1

        # Compile the profile before touching the running Zoom. A rejected rule
        # would otherwise surface as an unexplained failure to launch, and Zoom
        # would already have been killed by then. This fails closed: there is no
        # unsandboxed retry.
        if ! profile_error="$(/usr/bin/sandbox-exec -f "$profile_path" /usr/bin/true 2>&1)"; then
          echo "Error: macOS rejected the Zoom sandbox profile, so Zoom was not started. Details: $profile_error" >&2
          exit 1
        fi

        # Sandbox mode is required for 1132 Fixer. Normal Zoom launch mode does
        # not work for this workflow, so there is intentionally no open -a
        # fallback here.
        echo "Launch mode: persistentSandbox"
        stop_zoom_processes
        zoom_app=\(quotedAppPath)
        if [ ! -x /usr/bin/codesign ] || ! /usr/bin/codesign --verify --strict -R=\(shellSingleQuote(ZoomBundleVerifier.makeRequirement())) "$zoom_app" >/dev/null 2>&1; then
          echo "Error: Fresh Zoom signature verification (Team ID and us.zoom.xos identifier) failed; refusing to launch $zoom_binary." >&2
          exit 1
        fi
        /usr/bin/sandbox-exec -f "$profile_path" "$zoom_binary" >/dev/null 2>&1 &
        sandbox_pid=$!
        stable=0
        while [ "$stable" -lt 4 ]; do
          /bin/sleep 1
          if ! tracked_sandbox_child_is_running; then
            echo "Launch provenance: unknown. The tracked sandbox child exited or changed identity; another Zoom process is not accepted as proof." >&2
            exit 1
          fi
          stable=$((stable + 1))
        done
        echo "Tracked sandbox-exec child remained active. Independently starting normal Zoom bypasses this launcher's protection."
        exit 0
        """
    }
}
