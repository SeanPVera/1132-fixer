import Testing
import Foundation
@testable import _132Fixer

@Suite("ShellCommands")
struct ShellCommandsTests {

    // MARK: - Shell Quoting

    @Test func shellSingleQuoteSimple() {
        #expect(ShellCommands.shellSingleQuote("hello") == "'hello'")
    }

    @Test func shellSingleQuoteWithSingleQuote() {
        let result = ShellCommands.shellSingleQuote("it's")
        #expect(result.contains(#"'\''"#))
    }

    @Test func shellSingleQuoteEmpty() {
        #expect(ShellCommands.shellSingleQuote("") == "''")
    }

    @Test func shellSingleQuoteSpecialChars() {
        #expect(ShellCommands.shellSingleQuote("a b$c;d|e") == "'a b$c;d|e'")
    }

    // MARK: - MAC Address Validation

    @Test func validMACAddress() {
        #expect(ShellCommands.isValidMACAddress("02:ab:cd:ef:12:34"))
        #expect(ShellCommands.isValidMACAddress("AA:BB:CC:DD:EE:FF"))
    }

    @Test func invalidMACAddress() {
        #expect(!ShellCommands.isValidMACAddress(""))
        #expect(!ShellCommands.isValidMACAddress("not-a-mac"))
        #expect(!ShellCommands.isValidMACAddress("02:ab:cd:ef:12"))
        #expect(!ShellCommands.isValidMACAddress("02:ab:cd:ef:12:34:56"))
        #expect(!ShellCommands.isValidMACAddress("02-ab-cd-ef-12-34"))
        #expect(!ShellCommands.isValidMACAddress("GG:HH:II:JJ:KK:LL"))
    }

    @Test func generateRandomMACAddress() throws {
        let mac = try ShellCommands.generateRandomMACAddress()
        #expect(ShellCommands.isValidMACAddress(mac))

        let firstByte = UInt8(mac.prefix(2), radix: 16)!
        #expect(firstByte & 0x02 != 0, "Locally administered bit should be set")
        #expect(firstByte & 0x01 == 0, "Unicast bit should be clear")
    }

    @Test func generatedMACsAreRandom() throws {
        let mac1 = try ShellCommands.generateRandomMACAddress()
        let mac2 = try ShellCommands.generateRandomMACAddress()
        #expect(mac1 != mac2)
    }

    // MARK: - Interface Name Validation

    @Test func safeInterfaceNames() {
        #expect(ShellCommands.isSafeInterfaceName("en0"))
        #expect(ShellCommands.isSafeInterfaceName("en1"))
        #expect(ShellCommands.isSafeInterfaceName("bridge0"))
    }

    @Test func unsafeInterfaceNames() {
        #expect(!ShellCommands.isSafeInterfaceName(""))
        #expect(!ShellCommands.isSafeInterfaceName("en 0"))
        #expect(!ShellCommands.isSafeInterfaceName("en0;rm"))
        #expect(!ShellCommands.isSafeInterfaceName("en0|cat"))
        #expect(!ShellCommands.isSafeInterfaceName("../etc"))
    }

    // MARK: - Parse Default Route

    @Test func parseDefaultRouteInterface() throws {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        let device = try ShellCommands.parseDefaultRouteInterface(from: output)
        #expect(device == "en0")
    }

    @Test func parseDefaultRouteNoInterface() {
        let output = "route: writing to routing socket: not in table"
        #expect(throws: (any Error).self) {
            try ShellCommands.parseDefaultRouteInterface(from: output)
        }
    }

    @Test func parseDefaultRouteVPNInterface() {
        let output = """
           route to: default
          interface: utun0
        """
        #expect(throws: (any Error).self) {
            try ShellCommands.parseDefaultRouteInterface(from: output)
        }
    }

    // MARK: - Parse Hardware Ports

    @Test func parseHardwarePorts() {
        let output = """
        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: Thunderbolt Ethernet Slot 1
        Device: en1
        Ethernet Address: 11:22:33:44:55:66
        """
        let result = ShellCommands.parseHardwarePorts(from: output)
        #expect(result["en0"] == "Wi-Fi")
        #expect(result["en1"] == "Thunderbolt Ethernet Slot 1")
    }

    @Test func parseHardwarePortsEmpty() {
        let result = ShellCommands.parseHardwarePorts(from: "")
        #expect(result.isEmpty)
    }

    // MARK: - Classify Interface

    @Test func classifyWiFi() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "Wi-Fi")
        #expect(kind == .wifi)
    }

    @Test func classifyEthernet() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "Thunderbolt Ethernet Slot 1")
        #expect(kind == .ethernet)
    }

    @Test func classifyUSBLANAsEthernet() throws {
        let kind = try ShellCommands.classifySupportedInterface(hardwarePortName: "USB 10/100/1000 LAN")
        #expect(kind == .ethernet)
    }

    @Test func classifyUnsupported() {
        #expect(throws: (any Error).self) {
            try ShellCommands.classifySupportedInterface(hardwarePortName: "Bluetooth PAN")
        }
    }

    // MARK: - Parse Network Service Order

    @Test func parseNetworkServiceOrder() {
        let output = """
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) Thunderbolt Ethernet Slot 1
        (Hardware Port: Thunderbolt Ethernet Slot 1, Device: en1)
        """
        let result = ShellCommands.parseNetworkServiceOrder(from: output)
        #expect(result["en0"] == "Wi-Fi")
        #expect(result["en1"] == "Thunderbolt Ethernet Slot 1")
    }

    // MARK: - AppleScript Generation

    @Test func appleScriptDoShellScript() {
        let result = ShellCommands.appleScriptDoShellScript("echo hello", administratorPrivileges: false)
        // "echo hello" encoded in base64 is ZWNobyBoZWxsbw==
        #expect(result == #"do shell script "/bin/bash -c \"$(/bin/echo 'ZWNobyBoZWxsbw==' | /usr/bin/base64 --decode)\"""#)
    }

    @Test func appleScriptDoShellScriptAdmin() {
        let result = ShellCommands.appleScriptDoShellScript("echo hello", administratorPrivileges: true)
        #expect(result == #"do shell script "/bin/bash -c \"$(/bin/echo 'ZWNobyBoZWxsbw==' | /usr/bin/base64 --decode)\"" with administrator privileges"#)
    }

    @Test func appleScriptEscapesBackslashes() {
        let result = ShellCommands.appleScriptDoShellScript(#"echo \"test\""#, administratorPrivileges: false)
        // 'echo \"test\"' encoded in base64 is ZWNobyBcInRlc3RcIg==
        #expect(result == #"do shell script "/bin/bash -c \"$(/bin/echo 'ZWNobyBcInRlc3RcIg==' | /usr/bin/base64 --decode)\"""#)
    }

    @Test func appleScriptComplexPayload() {
        let payload = #"echo "hello \n world" 'test'"#
        let result = ShellCommands.appleScriptDoShellScript(payload, administratorPrivileges: true)
        // payload encoded in base64 is ZWNobyAiaGVsbG8gXG4gd29ybGQiICd0ZXN0Jw==
        #expect(result == #"do shell script "/bin/bash -c \"$(/bin/echo 'ZWNobyAiaGVsbG8gXG4gd29ybGQiICd0ZXN0Jw==' | /usr/bin/base64 --decode)\"" with administrator privileges"#)
    }

    // MARK: - VPN Detection

    @Test func vpnDetection() {
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "utun0") }
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "ppp0") }
        #expect(throws: (any Error).self) { try ShellCommands.ensureVPNIsNotActive(interfaceName: "ipsec0") }
        try! ShellCommands.ensureVPNIsNotActive(interfaceName: "en0")
        try! ShellCommands.ensureVPNIsNotActive(interfaceName: "en1")
    }

    // MARK: - Spoof Command Generation

    @Test func makeSpoofCommand() {
        let cmd = ShellCommands.makeSpoofCommand(device: "en0", spoofedMAC: "02:ab:cd:ef:12:34", networkService: "Wi-Fi")
        #expect(cmd.contains("ifconfig"))
        #expect(cmd.contains("'en0'"))
        #expect(cmd.contains("'02:ab:cd:ef:12:34'"))
        #expect(cmd.contains("networksetup"))
        #expect(cmd.contains("'Wi-Fi'"))
    }

    @Test func makeVerifyMACCommand() {
        let cmd = ShellCommands.makeVerifyMACCommand(device: "en0")
        #expect(cmd.contains("ifconfig"))
        #expect(cmd.contains("'en0'"))
        #expect(cmd.contains("ether"))
    }

    @Test func normalizePrivateAddressModeOutput() {
        #expect(ShellCommands.normalizePrivateAddressModeOutput("Rotating\n") == "rotating")
        #expect(ShellCommands.normalizePrivateAddressModeOutput("** Error: The command is not recognized.") == "unsupported")
        #expect(ShellCommands.normalizePrivateAddressModeOutput("networksetup -listnetworkserviceorder\nnetworksetup -printcommands") == "unsupported")
    }

    @Test func makeResetZoomDataCommandUsesProvidedHome() {
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "/Users/test user")
        #expect(cmd.contains("home='/Users/test user'"))
        #expect(cmd.contains("Application Support/zoom.us"))
        #expect(cmd.contains("exit \"$remaining\""))
    }

    @Test func makeResetZoomDataCommandRefusesEmptyHome() {
        // An empty home would rewrite every target to a system-level /Library path.
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "")
        #expect(cmd.contains(#"if [ -z "$home" ]; then"#))
        #expect(cmd.contains("refusing to delete system-level paths"))
    }

    // MARK: - Backup Pruning

    @Test func backupCommandPrunesOlderSnapshots() {
        let cmd = ShellCommands.makeBackupZoomDataCommand()
        // Default retention of 5 keeps entries 1...5 and deletes from entry 6 on.
        #expect(cmd.contains("/usr/bin/tail -n +6"))
        #expect(cmd.contains(#"/bin/rm -rf "$backup_root/$stale""#))
    }

    @Test func backupCommandRetentionIsConfigurable() {
        #expect(ShellCommands.makeBackupZoomDataCommand(retainedBackupCount: 1).contains("/usr/bin/tail -n +2"))
        #expect(ShellCommands.makeBackupZoomDataCommand(retainedBackupCount: 10).contains("/usr/bin/tail -n +11"))
        // A zero/negative count must still keep the snapshot just written.
        #expect(ShellCommands.makeBackupZoomDataCommand(retainedBackupCount: 0).contains("/usr/bin/tail -n +2"))
    }

    @Test func backupCommandEchoesOnlyTheBackupPath() {
        // AppViewModel consumes stdout as the backup path, so nothing else may print.
        let cmd = ShellCommands.makeBackupZoomDataCommand()
        let echoLines = cmd.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("echo ") }
        #expect(echoLines == [#"echo "$backup_dir""#])
    }

    // MARK: - Updaters

    @Test func stopZoomUpdatersDoesNotPersistentlyDisableUpdates() {
        // `launchctl disable` survives reboots and is never undone, which would leave
        // Zoom permanently without security updates.
        #expect(!ShellCommands.stopZoomUpdaters.contains("launchctl disable"))
        #expect(ShellCommands.stopZoomUpdaters.contains("launchctl bootout"))
    }

    @Test func stopZoomUpdatersUsesValidDomainTargets() {
        // "user" without a UID is not a valid launchctl domain target.
        #expect(ShellCommands.stopZoomUpdaters.contains(#"for domain in "gui/$uid" "user/$uid"; do"#))
    }

    @Test func zoomSandboxProfileAllowsCameraAndMicrophone() {
        #expect(ShellCommands.zoomSandboxProfile.contains("(allow device-camera)"))
        #expect(ShellCommands.zoomSandboxProfile.contains("(allow device-microphone)"))
        #expect(ShellCommands.zoomSandboxProfile.contains("(allow iokit-get-properties)"))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""AppleH13CamInUserClient""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""AppleUSBHostFrameworkInterfaceClient""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""IOUSBInterfaceUserClientV3""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.VDCAssistant""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.tccd""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.tccd.system""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.applecamerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.appleh13camerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.appleh16camerad""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.AVCAssistant""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.IIDCVideoAssistant""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.iOSScreenCaptureAssistant""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.registerassistantservice.system-extensions""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.cmio.system-extensions""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.coremedia.endpoint.xpc""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.mediaexperience.endpoint.xpc""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.runningboard""#))
        #expect(ShellCommands.zoomSandboxProfile.contains(#""com.apple.videoconference.camera""#))
    }

    // MARK: - Sandbox Profile Hardening
    //
    // The profile is a denylist over `(allow default)`. SBPL resolves the *last*
    // matching rule, so both the denies below the blanket allows and the ordering
    // of the /Users deny against the home allow-back are load-bearing.

    private func testProfile(home: String = "/Users/tester") -> String {
        ShellCommands.makeZoomSandboxProfile(homeDirectory: home)
    }

    @Test func zoomSandboxProfileDeniesHardwareIdentityProperties() {
        let profile = testProfile()
        for property in [
            "IOPlatformSerialNumber",
            "IOPlatformUUID",
            "IOMACAddress",
            "board-id",
            "chip-id",
            "die-id",
            "local-mac-address",
            "mlb-serial-number",
            "nvram-proxy-data",
            "platform-uuid",
            "serial-number",
            "system-serial-number",
            "unique-chip-id"
        ] {
            #expect(profile.contains(#"(iokit-property "\#(property)")"#), "missing deny for \(property)")
        }
    }

    @Test func zoomSandboxProfileKeepsPeripheralPropertiesReadable() {
        // An iokit-property filter matches every registry entry, not just the
        // platform node, so denying these generic keys would break camera and USB
        // device enumeration — which sandbox mode has to preserve.
        let profile = testProfile()
        #expect(!profile.contains(#"(iokit-property "model")"#))
        #expect(!profile.contains(#"(iokit-property "manufacturer")"#))
        #expect(!profile.contains(#"(iokit-property "SerialNumber")"#))
    }

    @Test func zoomSandboxProfileDeniesFingerprintingCommandLineTools() {
        let profile = testProfile()
        #expect(profile.contains("(deny process-exec"))
        for tool in [
            "/bin/hostname",
            "/sbin/ifconfig",
            "/usr/bin/dscl",
            "/usr/libexec/remotectl",
            "/usr/sbin/ioreg",
            "/usr/sbin/networksetup",
            "/usr/sbin/nvram",
            "/usr/sbin/scutil",
            "/usr/sbin/system_profiler"
        ] {
            #expect(profile.contains(#"(literal "\#(tool)")"#), "missing exec deny for \(tool)")
        }
    }

    @Test func zoomSandboxProfileDeniesUniqueSysctlIdentifiers() {
        let profile = testProfile()
        #expect(profile.contains(#"(sysctl-name "kern.uuid")"#))
        // hw.model is shared by millions of machines and Zoom uses it to pick
        // codecs, so it stays readable.
        #expect(!profile.contains(#"(sysctl-name "hw.model")"#))
    }

    @Test func zoomSandboxProfileDeniesNetworkIdentityFiles() {
        let profile = testProfile()
        for path in [
            "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist",
            "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist",
            "/Library/Preferences/SystemConfiguration/com.apple.network.identification.plist",
            "/Library/Preferences/com.apple.Bluetooth.plist"
        ] {
            #expect(profile.contains(#"(literal "\#(path)")"#), "missing read deny for \(path)")
        }
    }

    @Test func zoomSandboxProfileScopesPrivateDataRulesToTheGivenHome() {
        let profile = testProfile()
        #expect(profile.contains(#"(subpath "/Users/tester/.ssh")"#))
        #expect(profile.contains(#"(subpath "/Users/tester/Library/Keychains")"#))
        #expect(profile.contains(#"(subpath "/Users/tester/Library/Application Support/1132Fixer")"#))
        #expect(profile.contains(#"(literal "/Users/tester/.zsh_history")"#))
        // The profile is not run through a shell, so nothing may rely on expansion.
        #expect(!profile.contains("$HOME"))
        #expect(!profile.contains("~/"))
    }

    @Test func zoomSandboxProfileOrdersUsersDenyBeforeHomeAllowBack() {
        // Last matching rule wins: the allow-back must follow the /Users deny or
        // Zoom cannot read its own data, and the private-data denies must follow
        // the allow-back or they are undone by it.
        let profile = testProfile()
        guard
            let othersDeny = profile.range(of: #"(deny file-read* (subpath "/Users"))"#)?.lowerBound,
            let homeAllow = profile.range(of: #"(allow file-read* (subpath "/Users/tester"))"#)?.lowerBound,
            let privateDeny = profile.range(of: #"(subpath "/Users/tester/.ssh")"#)?.lowerBound
        else {
            Issue.record("Profile is missing the /Users deny, the home allow-back, or the private-data denies")
            return
        }
        #expect(othersDeny < homeAllow)
        #expect(homeAllow < privateDeny)
    }

    @Test func zoomSandboxProfileDeniesWritesToPersistenceAndBackupPaths() {
        let profile = testProfile()
        #expect(profile.contains("(deny file-write*"))
        // Stops the sandboxed session from reinstating the updater agents the
        // workflow just unloaded, and from tampering with this app's own backups
        // of Zoom's previous identity.
        #expect(profile.contains(#"(subpath "/Users/tester/Library/LaunchAgents")"#))
        #expect(profile.contains(#"(subpath "/Library/LaunchDaemons")"#))
    }

    @Test func zoomSandboxProfileNormalizesTrailingSlashInHome() {
        let profile = testProfile(home: "/Users/tester/")
        #expect(profile.contains(#"(subpath "/Users/tester/.ssh")"#))
        #expect(!profile.contains("//"))
        #expect(ShellCommands.normalizedSandboxHome("/Users/tester//") == "/Users/tester")
    }

    @Test func zoomSandboxProfileOmitsHomeRulesWhenHomeCannotAnchorSubpaths() {
        // Anchoring these rules at "/" would deny Zoom most of the filesystem, so
        // an unusable home drops them rather than widening them.
        #expect(ShellCommands.normalizedSandboxHome("/") == nil)
        #expect(ShellCommands.normalizedSandboxHome("") == nil)
        #expect(ShellCommands.normalizedSandboxHome("relative/path") == nil)

        for home in ["", "   ", "relative/path", "/"] {
            let profile = testProfile(home: home)
            #expect(!profile.contains(#"(deny file-read* (subpath "/Users"))"#))
            #expect(profile.contains("(allow device-camera)"))
            #expect(profile.contains(#"(iokit-property "IOPlatformSerialNumber")"#))
        }
    }

    @Test func sandboxStringLiteralEscapesQuotesAndBackslashes() {
        // An unescaped quote or backslash would end the SBPL string early and
        // silently change which paths the rule matches.
        #expect(ShellCommands.sandboxStringLiteral("/Users/plain") == #""/Users/plain""#)
        #expect(ShellCommands.sandboxStringLiteral(#"/Users/a"b"#) == #""/Users/a\"b""#)
        #expect(ShellCommands.sandboxStringLiteral(#"/Users/a\b"#) == #""/Users/a\\b""#)
    }

    @Test func zoomSandboxProfileEscapesHomePathsContainingQuotes() {
        let profile = testProfile(home: #"/Users/a"b"#)
        #expect(profile.contains(#"(subpath "/Users/a\"b/.ssh")"#))
    }

    @Test func zoomSandboxProfileIsAcceptedBySandboxExec() throws {
        // The app has no unsandboxed launch path, so a profile macOS refuses to
        // compile means Zoom cannot start at all. Compile it for real.
        let fileManager = FileManager.default
        let sandboxExec = "/usr/bin/sandbox-exec"
        guard fileManager.isExecutableFile(atPath: sandboxExec) else { return }

        let profileURL = fileManager.temporaryDirectory
            .appendingPathComponent("1132fixer-profile-\(UUID().uuidString).sb")
        try ShellCommands.zoomSandboxProfile.write(to: profileURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: profileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", profileURL.path, "/usr/bin/true"]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        // Drain before waiting so a verbose rejection cannot fill the pipe buffer.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let details = String(data: errorData, encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "sandbox-exec rejected the profile: \(details)")
    }

    @Test func stopZoomCommandsClearCaptureHelpers() {
        #expect(ShellCommands.stopZoom.contains(#""caphost""#))
        #expect(ShellCommands.stopZoom.contains(#""CptHost""#))

        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(cmd.contains(#""caphost""#))
        #expect(cmd.contains(#""CptHost""#))
    }

    @Test func makeLaunchZoomCommandUsesPersistentSandboxOnly() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(cmd.contains("Launch mode: persistentSandbox"))
        #expect(cmd.contains("/usr/bin/sandbox-exec"))
        #expect(!cmd.contains(#"/usr/bin/open -a "zoom.us""#))
        #expect(!cmd.contains("launch_normal_zoom"))
        #expect(!cmd.contains("normalOpen"))
    }

    @Test func launchCommandCompilesTheProfileBeforeTouchingZoom() {
        // A rejected rule would otherwise surface as an unexplained failure to
        // launch, after Zoom had already been killed.
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        guard
            let validate = cmd.range(of: #"/usr/bin/sandbox-exec -f "$profile_path" /usr/bin/true"#)?.lowerBound,
            let launch = cmd.range(of: #"/usr/bin/sandbox-exec -f "$profile_path" "$zoom_binary""#)?.lowerBound
        else {
            Issue.record("Launch script is missing the profile validation or the sandboxed launch")
            return
        }
        #expect(validate < launch)
        #expect(cmd.contains("macOS rejected the Zoom sandbox profile"))
    }

    @Test func launchCommandWritesProfileToThePerUserTempDirectory() {
        // /tmp is writable and listable by every local account.
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(cmd.contains(#"tmp_dir="${TMPDIR:-/tmp}""#))
        #expect(cmd.contains(#"/usr/bin/mktemp "${tmp_dir%/}/1132fixer.zoom-sandbox.XXXXXX""#))
        #expect(!cmd.contains(#"/usr/bin/mktemp "/tmp/"#))
    }

    @Test func makeLaunchZoomCommandFailsWhenZoomBinaryIsMissing() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: false)
        #expect(cmd.contains("Launch mode: sandboxRequiredMissingBinary"))
        #expect(cmd.contains("Zoom must be launched in sandbox mode"))
        #expect(!cmd.contains(#"/usr/bin/open -a "zoom.us""#))
        #expect(!cmd.contains("/usr/bin/sandbox-exec"))
    }

    // MARK: - Launch Command Quoting
    //
    // The launch script is executed by the caller as `/bin/bash -c <script>`. If the
    // script wraps itself in a second `/bin/bash -c '...'`, the single quotes emitted by
    // shellSingleQuote close that wrapper and the Zoom path reaches the outer shell
    // unquoted — a path with a space silently truncates the script (exiting 0 without
    // launching Zoom) and a path containing `$(...)` executes.

    @Test func launchCommandDoesNotNestASecondShell() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(!cmd.contains("/bin/bash -c"))
    }

    @Test func launchCommandQuotesPathContainingSpaces() {
        let path = "/Volumes/My Disk/zoom.us.app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: path, zoomBinaryExists: true)
        #expect(cmd.contains("zoom_binary='\(path)'"))
    }

    @Test func launchCommandQuotesPathContainingShellMetacharacters() {
        let path = "/tmp/a$(touch /tmp/pwned)`id`;echo.app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: path, zoomBinaryExists: true)
        #expect(cmd.contains("zoom_binary='\(path)'"))
        // The path must appear only inside the single-quoted assignment.
        #expect(cmd.components(separatedBy: path).count == 2)
    }

    @Test func launchCommandEscapesSingleQuotesInPath() {
        let path = "/tmp/it's/zoom.us.app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: path, zoomBinaryExists: true)
        #expect(cmd.contains(#"zoom_binary='/tmp/it'\''s/zoom.us.app/Contents/MacOS/zoom.us'"#))
    }

    @Test func missingBinaryCommandQuotesPathInsteadOfInterpolatingIt() {
        let path = "/tmp/a$(touch /tmp/pwned).app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: path, zoomBinaryExists: false)
        #expect(cmd.contains("zoom_binary='\(path)'"))
        // The message must reference the shell variable, not the raw path.
        #expect(cmd.contains("not found at $zoom_binary"))
        #expect(!cmd.contains("not found at \(path)"))
    }

    // MARK: - Network Identity Strategy

    @Test func rotatingPrivateWiFiAddressIsReachableOnBlockedWiFi() {
        // Apple Silicon + macOS 14+ on Wi-Fi: the rotating-address path must win. Testing
        // isMacSpoofingDisabledForCurrentOS first would make this branch unreachable.
        let strategy = ShellCommands.networkIdentityStrategy(
            isWiFi: true,
            isMacSpoofingBlockedOnWiFi: true,
            isMacSpoofingDisabledForCurrentOS: true
        )
        #expect(strategy == .rotatingPrivateWiFiAddress)
    }

    @Test func ethernetOnModernMacOSIsUnsupported() {
        let strategy = ShellCommands.networkIdentityStrategy(
            isWiFi: false,
            isMacSpoofingBlockedOnWiFi: true,
            isMacSpoofingDisabledForCurrentOS: true
        )
        #expect(strategy == .unsupported)
    }

    @Test func legacyMACSpoofUsedWhenNotDisabled() {
        let wifi = ShellCommands.networkIdentityStrategy(
            isWiFi: true,
            isMacSpoofingBlockedOnWiFi: false,
            isMacSpoofingDisabledForCurrentOS: false
        )
        let ethernet = ShellCommands.networkIdentityStrategy(
            isWiFi: false,
            isMacSpoofingBlockedOnWiFi: false,
            isMacSpoofingDisabledForCurrentOS: false
        )
        #expect(wifi == .legacyMACSpoof)
        #expect(ethernet == .legacyMACSpoof)
    }

    // MARK: - Custom Zoom Location

    @Test func zoomBinaryPathIsDerivedFromAppBundlePath() {
        #expect(ShellCommands.zoomBinaryPath(forAppPath: "/Applications/zoom.us.app")
            == "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
        #expect(ShellCommands.zoomBinaryPath(forAppPath: "/Users/me/Apps/zoom.us.app")
            == "/Users/me/Apps/zoom.us.app/Contents/MacOS/zoom.us")
    }

    @Test func makeLaunchZoomCommandUsesCustomBinaryPath() {
        let customBinary = "/Users/me/Apps/zoom.us.app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: customBinary, zoomBinaryExists: true)
        #expect(cmd.contains(customBinary))
        #expect(cmd.contains("Launch mode: persistentSandbox"))
        #expect(cmd.contains("/usr/bin/sandbox-exec"))
    }

    @Test func makeLaunchZoomCommandMissingBinaryMentionsCustomPath() {
        let customBinary = "/Users/me/Apps/zoom.us.app/Contents/MacOS/zoom.us"
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: customBinary, zoomBinaryExists: false)
        #expect(cmd.contains("Launch mode: sandboxRequiredMissingBinary"))
        #expect(cmd.contains(customBinary))
        #expect(!cmd.contains("/usr/bin/sandbox-exec"))
    }

    // MARK: - Machine Architecture

    @Test func machineArchitecture() {
        let arch = ShellCommands.machineArchitecture()
        #expect(!arch.isEmpty)
        #expect(arch == "arm64" || arch == "x86_64")
    }
}
