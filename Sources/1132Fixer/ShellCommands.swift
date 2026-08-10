import Foundation

/// Resolves the Zoom application location, allowing the user to select a custom
/// path when Zoom is not installed in the default `/Applications` location.
///
/// Sandbox-mode launch behavior is unchanged: the resolved binary is always run
/// through `sandbox-exec`. Only the location of the `zoom.us.app` bundle is
/// configurable.
enum ZoomLocation {
    private static let defaultsKey = "customZoomAppPath"

    static var defaultAppPath: String { ShellCommands.defaultZoomAppPath }

    /// The user-selected `zoom.us.app` bundle path, if one has been chosen.
    static var customAppPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: defaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty == false) ? value : nil
        }
        set {
            let defaults = UserDefaults.standard
            if let path = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                defaults.set(path, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// The `zoom.us.app` bundle path currently in effect (custom if set, else default).
    static var appPath: String { customAppPath ?? defaultAppPath }

    /// The Zoom executable path currently in effect.
    static var binaryPath: String { ShellCommands.zoomBinaryPath(forAppPath: appPath) }

    /// Whether a usable Zoom executable exists at the currently-effective location.
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: binaryPath) }

    /// Validates that a chosen bundle path is a `zoom.us.app` containing the Zoom
    /// executable. Returns the normalized bundle path, or `nil` if invalid.
    static func validatedAppPath(_ selectedPath: String) -> String? {
        let path = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let binary = ShellCommands.zoomBinaryPath(forAppPath: path)
        guard FileManager.default.fileExists(atPath: binary) else { return nil }
        return path
    }
}

enum ShellCommands {
    static let bashPath = "/bin/bash"
    static let osascriptPath = "/usr/bin/osascript"
    static let defaultZoomAppPath = "/Applications/zoom.us.app"

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

    static func appleScriptDoShellScript(_ command: String, administratorPrivileges: Bool) -> String {
        let base64Command = Data(command.utf8).base64EncodedString()
        let privilegeClause = administratorPrivileges ? " with administrator privileges" : ""
        return "do shell script \"/bin/bash -c \\\"$(/bin/echo '\(base64Command)' | /usr/bin/base64 --decode)\\\"\"\(privilegeClause)"
    }

    // MARK: - Command Strings

    static let stopZoom = #"""
    zoom_processes="zoom.us caphost CptHost"
    if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
      for proc in $zoom_processes; do
        /usr/bin/killall "$proc" 2>/dev/null || true
      done
      echo "Zoom was running and has been closed."
      for i in {1..10}; do
        if ! /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 && ! /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 && ! /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
          break
        fi
        /bin/sleep 0.5
      done
      if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
        for proc in $zoom_processes; do
          /usr/bin/killall -9 "$proc" 2>/dev/null || true
        done
        /bin/sleep 1
      fi
    fi
    """#

    /// Stops Zoom's updaters for the current login session only.
    ///
    /// `launchctl disable` is deliberately not used here: it persists across reboots
    /// and is never undone by this app, which would leave Zoom permanently without
    /// security updates. It also requires root, so it silently failed in practice.
    static let stopZoomUpdaters = #"""
    uid="$(/usr/bin/id -u)"
    stopped=""

    for proc in zAutoUpdate zPTUpdaterUI ZoomUpdater; do
      if /usr/bin/pkill -x "$proc" 2>/dev/null; then
        stopped="$stopped $proc"
      fi
    done

    for domain in "gui/$uid" "user/$uid"; do
      for label in us.zoom.zAutoUpdate us.zoom.ZoomUpdater us.zoom.zPTUpdaterUI; do
        /bin/launchctl bootout "$domain" "/Library/LaunchAgents/$label.plist" 2>/dev/null || true
        /bin/launchctl bootout "$domain" "$HOME/Library/LaunchAgents/$label.plist" 2>/dev/null || true
      done
    done

    if [ -n "$stopped" ]; then
      echo "Stopped Zoom updater processes:$stopped"
    else
      echo "No Zoom updater processes were running."
    fi
    echo "Updater agents unloaded for this login session; macOS restores them at the next login."
    """#

    static let refreshDNSAppleScript = #"do shell script "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder" with administrator privileges"#

    /// Clears Zoom's local state. Runs as the current user: every path is inside the
    /// user's own home directory, so elevating this to root only widened the blast
    /// radius of the `rm -rf` without enabling anything.
    static func makeResetZoomDataCommand(homeDirectory: String) -> String {
        let home = shellSingleQuote(homeDirectory)
        return """
        home=\(home)
        if [ -z "$home" ]; then
          echo "Reset Zoom data: home directory is empty; refusing to delete system-level paths." >&2
          exit 1
        fi

        zoom_data="$home/Library/Application Support/zoom.us"
        zoom_cache="$home/Library/Caches/us.zoom.xos"
        zoom_prefs="$home/Library/Preferences/us.zoom.xos.plist"
        zoom_logs="$home/Library/Logs/zoom.us.log"
        zoom_saved_state="$home/Library/Saved Application State/us.zoom.xos.savedState"

        /bin/rm -rf "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"
        /bin/rm -f "$zoom_logs"*
        HOME="$home" /usr/bin/defaults delete us.zoom.xos >/dev/null 2>&1 || true

        remaining=0
        for path in "$zoom_data" "$zoom_cache" "$zoom_prefs" "$zoom_saved_state"; do
          if [ -e "$path" ]; then
            echo "Warning: Could not remove $path" >&2
            remaining=1
          fi
        done

        if /bin/ls "$zoom_logs"* >/dev/null 2>&1; then
          echo "Warning: Could not remove Zoom log files matching $zoom_logs*" >&2
          remaining=1
        fi

        exit "$remaining"
        """
    }

    /// Copies Zoom's local state aside before it is cleared, keeping only the most
    /// recent `retainedBackupCount` snapshots. Without pruning, every run left another
    /// full copy of Zoom's Application Support and Caches on disk forever.
    static func makeBackupZoomDataCommand(retainedBackupCount: Int = 5) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let firstStaleEntry = max(retainedBackupCount, 1) + 1
        return """
        backup_root="$HOME/Library/Application Support/1132Fixer/Backups"
        backup_dir="$backup_root/\(timestamp)"
        mkdir -p "$backup_dir"
        for src in \
          "$HOME/Library/Application Support/zoom.us" \
          "$HOME/Library/Caches/us.zoom.xos" \
          "$HOME/Library/Preferences/us.zoom.xos.plist" \
          "$HOME/Library/Saved Application State/us.zoom.xos.savedState"; do
          [ -e "$src" ] && cp -a "$src" "$backup_dir/" 2>/dev/null || true
        done

        # Prune older snapshots. Directory names are generated by this app, so they
        # contain no spaces or newlines.
        /bin/ls -1t "$backup_root" 2>/dev/null | /usr/bin/tail -n +\(firstStaleEntry) | while IFS= read -r stale; do
          if [ -n "$stale" ]; then
            /bin/rm -rf "$backup_root/$stale"
          fi
        done

        echo "$backup_dir"
        """
    }

    // MARK: - MAC Address

    static func generateRandomMACAddress() throws -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE // locally administered + unicast

        let mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        guard isValidMACAddress(mac) else {
            throw AppError.general("Generate MAC address: Failed to generate a valid MAC address.")
        }
        return mac
    }

    static func isValidMACAddress(_ value: String) -> Bool {
        let pattern = #"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Interface Validation

    static func isSafeInterfaceName(_ value: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Network Parsing

    enum InterfaceKind: String {
        case wifi = "Wi-Fi"
        case ethernet = "Ethernet"
    }

    struct InterfaceInfo {
        let device: String
        let hardwarePort: String
        let networkService: String
        let kind: InterfaceKind
    }

    static func parseDefaultRouteInterface(from output: String) throws -> String {
        var foundInterface: String?
        var parseError: Error?

        output.enumerateLines { rawLine, stop in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("interface:") else { return }

            let value = line.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            guard isSafeInterfaceName(value) else {
                parseError = AppError.general("Detect active network interface: Invalid interface name '\(value)'.")
                stop = true
                return
            }

            do {
                try ensureVPNIsNotActive(interfaceName: value)
                foundInterface = value
            } catch {
                parseError = error
            }
            stop = true
        }

        if let parseError {
            throw parseError
        }

        if let foundInterface {
            return foundInterface
        }

        throw AppError.general("Detect active network interface: No default route interface was found. Make sure you are connected to Wi-Fi or Ethernet. If you just disconnected a VPN, wait a few seconds for your connection to restore and try again.")
    }

    static func ensureVPNIsNotActive(interfaceName: String) throws {
        let normalized = interfaceName.lowercased()
        let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

        if vpnPrefixes.contains(where: normalized.hasPrefix) {
            throw AppError.general("""
VPN detected on interface '\(interfaceName)'. \
MAC spoofing cannot work while a VPN is active because the VPN tunnel hides your real network interface. \
Turn off your VPN, wait a few seconds for your normal connection to restore, and run Start Zoom again.
""")
        }
    }

    static func parseHardwarePorts(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentHardwarePort: String?

        output.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Hardware Port:") {
                currentHardwarePort = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
                return
            }

            if line.hasPrefix("Device:"), let hardwarePort = currentHardwarePort {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if isSafeInterfaceName(device) {
                    result[device] = hardwarePort
                }
            }
        }

        return result
    }

    static func classifySupportedInterface(hardwarePortName: String) throws -> InterfaceKind {
        let normalized = hardwarePortName.lowercased()

        if normalized.contains("wi-fi") || normalized.contains("wifi") {
            return .wifi
        }
        if normalized.contains("ethernet") {
            return .ethernet
        }
        if normalized.contains("usb") && normalized.contains("lan") {
            return .ethernet
        }

        throw AppError.general("Detect active network interface: Active interface '\(hardwarePortName)' is not supported. Only Wi-Fi and Ethernet are supported.")
    }

    static func parseNetworkServiceOrder(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var pendingServiceName: String?

        let pattern = #"\(Hardware Port: .*?, Device: ([^)]+)\)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        output.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }

            if line.hasPrefix("("), let closingParen = line.firstIndex(of: ")"), line.index(after: closingParen) < line.endIndex {
                let nameStart = line.index(after: closingParen)
                let serviceName = line[nameStart...].trimmingCharacters(in: .whitespaces)
                if !serviceName.isEmpty && !serviceName.hasPrefix("*") {
                    pendingServiceName = String(serviceName)
                } else {
                    pendingServiceName = nil
                }
                return
            }

            guard line.hasPrefix("(Hardware Port:"), let serviceName = pendingServiceName, let regex else { return }
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 1 else { return }

            let deviceRange = match.range(at: 1)
            guard deviceRange.location != NSNotFound else { return }

            let device = nsLine.substring(with: deviceRange).trimmingCharacters(in: .whitespaces)
            if isSafeInterfaceName(device) {
                result[device] = serviceName
            }
        }

        return result
    }

    // MARK: - System Checks

    static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let values = mirror.children.compactMap { child -> UInt8? in
            guard let value = child.value as? Int8, value != 0 else { return nil }
            return UInt8(value)
        }
        return String(bytes: values, encoding: .ascii) ?? "unknown"
    }

    static func isMacSpoofingBlockedOnWiFi() -> Bool {
        let isAppleSilicon = machineArchitecture() == "arm64"
        let isMacOS14OrLater = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        return isAppleSilicon && isMacOS14OrLater
    }

    static func isMacSpoofingDisabledForCurrentOS() -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
    }

    // MARK: - Network Identity Strategy

    /// How the workflow can change the machine's network identity on this OS and interface.
    enum NetworkIdentityStrategy: Equatable {
        /// `ifconfig lladdr` spoofing, which only works reliably before macOS 14.
        case legacyMACSpoof
        /// macOS 14+ replacement on Apple Silicon Wi-Fi: cycle the rotating Private Wi-Fi Address.
        case rotatingPrivateWiFiAddress
        /// No usable mechanism on this OS/interface combination.
        case unsupported
    }

    /// Decides the strategy. The Wi-Fi case is checked *first*: it only ever applies on
    /// macOS 14+, so testing `isMacSpoofingDisabledForCurrentOS` before it would make the
    /// rotating-address path unreachable.
    static func networkIdentityStrategy(
        isWiFi: Bool,
        isMacSpoofingBlockedOnWiFi: Bool,
        isMacSpoofingDisabledForCurrentOS: Bool
    ) -> NetworkIdentityStrategy {
        if isWiFi && isMacSpoofingBlockedOnWiFi {
            return .rotatingPrivateWiFiAddress
        }
        if isMacSpoofingDisabledForCurrentOS {
            return .unsupported
        }
        return .legacyMACSpoof
    }

    /// Strategy for the running system.
    static func networkIdentityStrategy(isWiFi: Bool) -> NetworkIdentityStrategy {
        networkIdentityStrategy(
            isWiFi: isWiFi,
            isMacSpoofingBlockedOnWiFi: isMacSpoofingBlockedOnWiFi(),
            isMacSpoofingDisabledForCurrentOS: isMacSpoofingDisabledForCurrentOS()
        )
    }

    // MARK: - Private Wi-Fi Address (Rotating MAC)

    static func makeGetPrivateAddressModeCommand(networkService: String) -> String {
        "/usr/sbin/networksetup -getPrivateNetworkAddress \(shellSingleQuote(networkService)) 2>/dev/null || echo 'unsupported'"
    }

    static func makeSetPrivateAddressModeCommand(networkService: String, mode: String) -> String {
        "/usr/sbin/networksetup -setPrivateNetworkAddress \(shellSingleQuote(networkService)) \(shellSingleQuote(mode))"
    }

    static func normalizePrivateAddressModeOutput(_ output: String) -> String {
        var normalizedLines: [String] = []
        var containsNotRecognizedOrUnsupported = false

        output.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !line.isEmpty {
                normalizedLines.append(line)
                if line.contains("not recognized") || line.contains("unsupported") || line.contains("networksetup -printcommands") {
                    containsNotRecognizedOrUnsupported = true
                }
            }
        }

        for mode in ["rotating", "fixed", "static", "off"] {
            if normalizedLines.contains(mode) {
                return mode
            }
        }

        if containsNotRecognizedOrUnsupported {
            return "unsupported"
        }

        let normalizedOutput = normalizedLines.joined(separator: "\n")
        for mode in ["rotating", "fixed", "static", "off"] {
            if normalizedOutput.contains(mode) {
                return mode
            }
        }

        return normalizedOutput.isEmpty ? "unsupported" : normalizedOutput
    }

    /// Cycles the Wi-Fi interface off then on to generate a new rotating MAC address.
    /// The interface is always brought back up, even if the down step fails.
    static func makeRotatingMACResetCommand(device: String) -> String {
        let off = "/usr/sbin/networksetup -setairportpower \(shellSingleQuote(device)) off"
        let sleep1 = "/bin/sleep 1"
        let on = "/usr/sbin/networksetup -setairportpower \(shellSingleQuote(device)) on"
        let sleep2 = "/bin/sleep 2"
        // Always run `on`, regardless of whether `off` succeeded
        return "{ \(off); \(sleep1); } 2>/dev/null || true; \(on); \(sleep2)"
    }

    // MARK: - MAC Spoof Command

    static func makeSpoofCommand(device: String, spoofedMAC: String, networkService: String) -> String {
        let setMACCommand = "(/sbin/ifconfig \(shellSingleQuote(device)) lladdr \(shellSingleQuote(spoofedMAC)) || /sbin/ifconfig \(shellSingleQuote(device)) ether \(shellSingleQuote(spoofedMAC)))"
        let interfaceDownCommand = "/sbin/ifconfig \(shellSingleQuote(device)) down"
        let interfaceUpCommand = "/sbin/ifconfig \(shellSingleQuote(device)) up"
        let disableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(networkService)) off"
        let enableServiceCommand = "/usr/sbin/networksetup -setnetworkserviceenabled \(shellSingleQuote(networkService)) on"
        let sleepShort = "/bin/sleep 1"
        let sleepReconnect = "/bin/sleep 2"

        let macAttempt = "(\(interfaceDownCommand) && \(sleepShort) && \(setMACCommand)) 2>/dev/null || true"
        let restoreUp = "\(interfaceUpCommand) 2>/dev/null || true"
        let recycleService = "\(disableServiceCommand) 2>/dev/null || true; \(sleepShort); \(enableServiceCommand)"
        return "\(macAttempt); \(restoreUp); \(sleepShort); \(recycleService); \(sleepReconnect)"
    }

    static func makeVerifyMACCommand(device: String) -> String {
        "/sbin/ifconfig \(shellSingleQuote(device)) | /usr/bin/awk '/^[[:space:]]*ether /{print $2; exit}'"
    }

    // MARK: - Launch Zoom

    // Zoom must stay inside sandbox-exec for this app. Do not replace this
    // profile-backed launch with /usr/bin/open or any other normal Zoom launch.

    /// Sandbox profile for the running user.
    static var zoomSandboxProfile: String {
        makeZoomSandboxProfile(homeDirectory: NSHomeDirectory())
    }

    /// Home-relative directories Zoom is denied read access to. Zoom needs none of
    /// them, and macOS treats 1132 Fixer as the TCC *responsible* process for the
    /// sandboxed session, so without these rules Zoom would inherit this app's
    /// standing when it reaches for TCC-protected data.
    ///
    /// `Application Support/1132Fixer` holds this app's own backups of Zoom's
    /// previous local state — readable, that is a copy of the very identity the
    /// workflow just cleared.
    private static let deniedHomeReadSubpaths = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".docker",
        ".config",
        "Library/Keychains",
        "Library/Containers",
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
    /// stops the sandboxed session from reinstating the updater agents the workflow
    /// just unloaded. This lasts only as long as the sandboxed process: the agent
    /// files are untouched, so Zoom still updates outside this app.
    private static let deniedHomeWriteSubpaths = [
        ".ssh",
        ".gnupg",
        ".aws",
        "Library/Keychains",
        "Library/LaunchAgents",
        "Library/Application Support/1132Fixer"
    ]

    /// Returns an absolute home path with trailing slashes trimmed, or `nil` when the
    /// value cannot anchor a `subpath` rule. `/` is rejected on purpose: anchoring
    /// these rules at the filesystem root would deny Zoom most of the disk.
    static func normalizedSandboxHome(_ homeDirectory: String) -> String? {
        var path = homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return path
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
    /// 2. **Private user data.** See `deniedHomeReadSubpaths`.
    ///
    /// SBPL resolves the *last* matching rule, so the denies below override the blanket
    /// allows above them, and the home allow-back overrides the `/Users` deny. Rule
    /// order in this profile is load-bearing.
    static func makeZoomSandboxProfile(homeDirectory: String) -> String {
        var profile = zoomSandboxProfilePrefix

        guard let home = normalizedSandboxHome(homeDirectory) else {
            return profile
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

    ; System-wide credentials and persistence.
    (deny file-read*
        (subpath "/Library/Keychains")
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

    static func makeLaunchZoomCommand(zoomBinaryPath: String) -> String {
        makeLaunchZoomCommand(
            zoomBinaryPath: zoomBinaryPath,
            zoomBinaryExists: FileManager.default.fileExists(atPath: zoomBinaryPath)
        )
    }

    static func makeLaunchZoomCommand(zoomBinaryExists: Bool) -> String {
        makeLaunchZoomCommand(zoomBinaryPath: zoomBinaryPath, zoomBinaryExists: zoomBinaryExists)
    }

    /// Builds the launch script that the caller hands to `/bin/bash -c`.
    ///
    /// The script must never wrap itself in another `/bin/bash -c '...'`: the single
    /// quotes produced by `shellSingleQuote` would close that wrapper's quoting, so the
    /// interpolated Zoom path would reach the outer shell unquoted. Interpolate paths
    /// only through `shellSingleQuote`, and reference them as `"$zoom_binary"`.
    static func makeLaunchZoomCommand(zoomBinaryPath: String, zoomBinaryExists: Bool) -> String {
        let quotedBinaryPath = shellSingleQuote(zoomBinaryPath)

        guard zoomBinaryExists else {
            return """
            zoom_binary=\(quotedBinaryPath)
            echo "Launch mode: sandboxRequiredMissingBinary"
            echo "Error: Zoom must be launched in sandbox mode, but the Zoom binary was not found at $zoom_binary. Install Zoom from https://zoom.us/download, or pick the correct Zoom location in 1132 Fixer, and try again."
            exit 1
            """
        }

        let encodedProfile = Data(zoomSandboxProfile.utf8).base64EncodedString()
        return """
        set -u

        zoom_binary=\(quotedBinaryPath)
        encoded_profile=\(shellSingleQuote(encodedProfile))

        # The per-user TMPDIR (mode 0700) rather than /tmp, which every local
        # account can write to and list.
        tmp_dir="${TMPDIR:-/tmp}"
        profile_path="$(/usr/bin/mktemp "${tmp_dir%/}/1132fixer.zoom-sandbox.XXXXXX")" || exit 1

        cleanup() {
          /bin/rm -f "$profile_path"
        }

        wait_for_sandboxed_zoom_stability() {
          required_consecutive="$1"
          max_attempts="$2"
          i=0
          stable=0
          while [ "$i" -lt "$max_attempts" ]; do
            if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
              stable=$((stable + 1))
              if [ "$stable" -ge "$required_consecutive" ]; then
                return 0
              fi
            else
              stable=0
            fi
            /bin/sleep 1
            i=$((i + 1))
          done
          return 1
        }

        stop_zoom_processes() {
          zoom_processes="zoom.us caphost CptHost"
          if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
            for proc in $zoom_processes; do
              /usr/bin/killall "$proc" 2>/dev/null || true
            done
            for i in {1..6}; do
              if ! /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 && ! /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 && ! /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
                break
              fi
              /bin/sleep 0.5
            done
            if /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1 || /usr/bin/pgrep -x "caphost" >/dev/null 2>&1 || /usr/bin/pgrep -x "CptHost" >/dev/null 2>&1; then
              for proc in $zoom_processes; do
                /usr/bin/killall -9 "$proc" 2>/dev/null || true
              done
              /bin/sleep 1
            fi
          fi
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
        /usr/bin/sandbox-exec -f "$profile_path" "$zoom_binary" >/dev/null 2>&1 &
        sandbox_pid=$!
        /bin/sleep 1

        if /bin/kill -0 "$sandbox_pid" 2>/dev/null || /usr/bin/pgrep -x "zoom.us" >/dev/null 2>&1; then
          echo "Heuristic: sandbox launch started"
        else
          echo "Heuristic: sandbox launch started = no"
          exit 1
        fi

        if wait_for_sandboxed_zoom_stability 4 15; then
          echo "Heuristic: sandbox launch stabilized"
          exit 0
        fi

        if /bin/kill -0 "$sandbox_pid" 2>/dev/null; then
          echo "Heuristic: sandbox process still running without process-name stability confirmation"
          exit 0
        fi

        echo "Heuristic: sandbox launch stabilized = no"
        exit 1
        """
    }
}
