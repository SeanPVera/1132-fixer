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

    @Test func makeResetZoomDataCommandUsesProvidedHome() {
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "/Users/test user")
        #expect(cmd.contains("home='/Users/test user'"))
        #expect(cmd.contains("Application Support/zoom.us"))
        #expect(cmd.contains("exit \"$remaining\""))
    }

    @Test func makeResetZoomDataCommandRefusesEmptyHome() {
        // An empty home would rewrite every target to a system-level /Library path.
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "")
        #expect(cmd.contains(#"/*) ;;"#))
        #expect(cmd.contains("refusing to delete anything"))
    }

    // MARK: - Sandbox Profile

    @Test func zoomSandboxProfileAllowsCameraAndMicrophone() {
        #expect(testProfile().contains("(allow device-camera)"))
        #expect(testProfile().contains("(allow device-microphone)"))
        #expect(testProfile().contains("(allow iokit-get-properties)"))
        #expect(testProfile().contains(#""AppleH13CamInUserClient""#))
        #expect(testProfile().contains(#""AppleUSBHostFrameworkInterfaceClient""#))
        #expect(testProfile().contains(#""IOUSBInterfaceUserClientV3""#))
        #expect(testProfile().contains(#""com.apple.cmio.VDCAssistant""#))
        #expect(testProfile().contains(#""com.apple.tccd""#))
        #expect(testProfile().contains(#""com.apple.tccd.system""#))
        #expect(testProfile().contains(#""com.apple.applecamerad""#))
        #expect(testProfile().contains(#""com.apple.appleh13camerad""#))
        #expect(testProfile().contains(#""com.apple.appleh16camerad""#))
        #expect(testProfile().contains(#""com.apple.cmio.AVCAssistant""#))
        #expect(testProfile().contains(#""com.apple.cmio.IIDCVideoAssistant""#))
        #expect(testProfile().contains(#""com.apple.cmio.iOSScreenCaptureAssistant""#))
        #expect(testProfile().contains(#""com.apple.cmio.registerassistantservice.system-extensions""#))
        #expect(testProfile().contains(#""com.apple.cmio.system-extensions""#))
        #expect(testProfile().contains(#""com.apple.coremedia.endpoint.xpc""#))
        #expect(testProfile().contains(#""com.apple.mediaexperience.endpoint.xpc""#))
        #expect(testProfile().contains(#""com.apple.runningboard""#))
        #expect(testProfile().contains(#""com.apple.videoconference.camera""#))
    }

    // MARK: - Sandbox Profile Hardening
    //
    // The profile is a denylist over `(allow default)`. SBPL resolves the *last*
    // matching rule, so both the denies below the blanket allows and the ordering
    // of the /Users deny against the home allow-back are load-bearing.

    private func testProfile(home: String = "/Users/tester") -> String {
        try! ShellCommands.makeZoomSandboxProfile(homeDirectory: home)
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
        // Stops the sandboxed session from installing login agents and from
        // tampering with backups left by earlier versions of this app.
        #expect(profile.contains(#"(subpath "/Users/tester/Library/LaunchAgents")"#))
        #expect(profile.contains(#"(subpath "/Library/LaunchDaemons")"#))
    }

    @Test func zoomSandboxProfileNormalizesTrailingSlashInHome() {
        let profile = testProfile(home: "/Users/tester/")
        #expect(profile.contains(#"(subpath "/Users/tester/.ssh")"#))
        #expect(!profile.contains("//"))
        #expect(ShellCommands.normalizedSandboxHome("/Users/tester//") == "/Users/tester")
    }

    @Test func invalidHomeCannotProduceAWeakenedSandboxProfile() {
        for home in ["", "   ", "relative/path", "/", "/Users/alice/..", "/Users/alice/../bob"] {
            #expect(throws: (any Error).self) { try ShellCommands.makeZoomSandboxProfile(homeDirectory: home) }
            let validation = ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: home)
            let launch = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", zoomBinaryExists: true, homeDirectory: home)
            #expect(validation.contains("exit 1"))
            #expect(!validation.contains("encoded_profile="))
            #expect(launch.contains("exit 1"))
            #expect(!launch.contains("stop_zoom_processes"))
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
        try #require(fileManager.isExecutableFile(atPath: sandboxExec), "Required sandbox canary cannot run without sandbox-exec")

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

    @Test func zoomSandboxProfileDeniesWritesToReadDeniedCredentialStores() {
        let profile = testProfile()
        guard let start = profile.range(of: "(deny file-write*\n", options: .backwards) else {
            Issue.record("Home write-deny block is missing")
            return
        }
        let writeBlock = String(profile[start.lowerBound...])
        for rule in [#"(subpath "/Users/tester/.kube")"#, #"(subpath "/Users/tester/.docker")"#, #"(literal "/Users/tester/.netrc")"#] {
            #expect(writeBlock.contains(rule), "missing write denial \(rule)")
        }
    }

    /// F-013: probes the compiled profile against a disposable home. Writes, creates and
    /// unlinks under credential paths fail; an ordinary file in the same home still works.
    @Test func zoomSandboxProfileBlocksCredentialWritesInADisposableHome() throws {
        let fileManager = FileManager.default
        let sandboxExec = "/usr/bin/sandbox-exec"
        try #require(fileManager.isExecutableFile(atPath: sandboxExec), "Required sandbox canary cannot run without sandbox-exec")
        // The fixture home must have no symlinked ancestors (the sandbox matches resolved
        // paths) and must survive `standardizingPath`, which strips a leading `/private`;
        // the per-user caches folder satisfies both, unlike the temporary directory.
        let caches = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let base = caches.appendingPathComponent("1132-cred-home-" + UUID().uuidString)
        defer { try? fileManager.removeItem(at: base) }
        try #require(ShellCommands.normalizedSandboxHome(base.path) == base.path, "Fixture home is not a canonical path")
        for directory in [".kube", ".docker"] {
            try fileManager.createDirectory(at: base.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data("original\n".utf8).write(to: base.appendingPathComponent(".netrc"))
        try Data("original\n".utf8).write(to: base.appendingPathComponent(".kube/config"))
        let profileURL = base.appendingPathComponent("profile.sb")
        try ShellCommands.makeZoomSandboxProfile(homeDirectory: base.path).write(to: profileURL, atomically: true, encoding: .utf8)

        func sandboxed(_ script: String) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sandboxExec)
            process.arguments = ["-f", profileURL.path, "/bin/sh", "-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        let home = ShellCommands.shellSingleQuote(base.path)
        #expect(try sandboxed("echo pwned > \(home)/.netrc") != 0)
        #expect(try sandboxed("echo pwned > \(home)/.kube/config") != 0)
        #expect(try sandboxed("echo new > \(home)/.docker/config.json") != 0)
        #expect(try sandboxed("rm -f \(home)/.kube/config") != 0)
        #expect(try String(contentsOf: base.appendingPathComponent(".netrc"), encoding: .utf8) == "original\n")
        #expect(try String(contentsOf: base.appendingPathComponent(".kube/config"), encoding: .utf8) == "original\n")
        #expect(!fileManager.fileExists(atPath: base.appendingPathComponent(".docker/config.json").path))
        #expect(try sandboxed("echo ok > \(home)/ordinary.txt") == 0)
    }

    @Test func stopZoomCommandsClearCaptureHelpers() {
        #expect(ShellCommands.stopZoom.contains(#""caphost""#))
        #expect(ShellCommands.stopZoom.contains(#""CptHost""#))
        #expect(ShellCommands.stopZoom.contains("refusing to modify Zoom data"))
        #expect(ShellCommands.stopZoom.contains("exit 1"))

        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        #expect(cmd.contains(#""caphost""#))
        #expect(cmd.contains(#""CptHost""#))
    }

    @Test func stopZoomFailsClosedWhenProcessesSurviveForceKill() {
        guard let forceKill = ShellCommands.stopZoom.range(of: #"/usr/bin/pkill -KILL -u "$uid" -x "$proc""#)?.upperBound,
              let refusal = ShellCommands.stopZoom.range(of: "refusing to modify Zoom data")?.lowerBound else {
            Issue.record("Stop command is missing its force-kill or final refusal check")
            return
        }
        #expect(forceKill < refusal)
        #expect(ShellCommands.stopZoom.contains("exit 1"))
    }

    @Test func sandboxReadinessCompilesProfileWithoutLaunchingZoom() {
        let cmd = ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: "/Users/test")
        #expect(cmd.contains(#"[ ! -x /usr/bin/sandbox-exec ]"#))
        #expect(cmd.contains(#"/usr/bin/sandbox-exec -f "$profile_path" /usr/bin/true"#))
        #expect(!cmd.contains("zoom.us"))
        #expect(!cmd.contains("/usr/bin/open"))
    }

    @Test func readinessAndLaunchUseTheSameProvidedHomeInTheirProfiles() throws {
        let home = "/Users/workflow home"
        let readiness = ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: home)
        let launch = ShellCommands.makeLaunchZoomCommand(
            zoomBinaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us",
            zoomBinaryExists: true,
            homeDirectory: home
        )

        let readinessProfile = try #require(decodedProfile(from: readiness))
        let launchProfile = try #require(decodedProfile(from: launch))
        #expect(readinessProfile == launchProfile)
        #expect(launchProfile.contains(#"(subpath "/Users/workflow home/.ssh")"#))
    }

    private func decodedProfile(from command: String) -> String? {
        guard let assignment = command.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("encoded_profile='") && $0.hasSuffix("'") }) else {
            return nil
        }
        let encoded = assignment.dropFirst("encoded_profile='".count).dropLast()
        return Data(base64Encoded: String(encoded)).flatMap { String(data: $0, encoding: .utf8) }
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

    @Test func standaloneSandboxValidationDoesNotTouchZoom() {
        let cmd = ShellCommands.makeSandboxProfileValidationCommand()
        #expect(cmd.contains(#"/usr/bin/sandbox-exec -f "$profile_path" /usr/bin/true"#))
        #expect(cmd.contains("sandbox-exec is unavailable"))
        #expect(cmd.contains("1132fixer.zoom-sandbox-check"))
        #expect(!cmd.contains("killall"))
        #expect(!cmd.contains("zoom_binary"))
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

    // MARK: - Time-bounded privileged commands

    @Test func resetCommandGuardsHomeBeforeAnyDeletion() {
        let cmd = ShellCommands.makeResetZoomDataCommand(homeDirectory: "/Users/test")
        let guardRange = cmd.range(of: "refusing to delete anything")
        let rmRange = cmd.range(of: "/bin/rm -rf")
        #expect(guardRange != nil)
        #expect(rmRange != nil)
        if let guardRange, let rmRange {
            #expect(guardRange.lowerBound < rmRange.lowerBound)
        }
        #expect(cmd.contains(#"[ ! -d "$home" ]"#))
        #expect(cmd.contains(#"[ "$home" = "/" ]"#))
    }

    @Test func safeHomeDirectoryValidation() {
        #expect(ShellCommands.isSafeHomeDirectory("/Users/test"))
        #expect(ShellCommands.isSafeHomeDirectory("/Users/test/"))
        #expect(!ShellCommands.isSafeHomeDirectory(""))
        #expect(!ShellCommands.isSafeHomeDirectory("/"))
        #expect(!ShellCommands.isSafeHomeDirectory("//"))
        #expect(!ShellCommands.isSafeHomeDirectory("Users/test"))
        #expect(!ShellCommands.isSafeHomeDirectory("~"))
        #expect(!ShellCommands.isSafeHomeDirectory("/tmp/.."))
        #expect(!ShellCommands.isSafeHomeDirectory("/Users/test/../other"))
    }

    @Test func appConfigurationMetadataPointsToForkAndGatesDebugEnvironment() {
        #expect(AppConfiguration.repositoryURL.absoluteString == "https://github.com/SeanPVera/1132-fixer")
        #expect(AppConfiguration.websiteURL.absoluteString == "https://1132-fixer.xyz")
        #expect(!AppConfiguration.repositoryURL.absoluteString.contains("PrimeUpYourLife"))
        #if DEBUG
        #expect(AppConfiguration.allowsDebugEnvironmentOverrides == true)
        #else
        #expect(AppConfiguration.allowsDebugEnvironmentOverrides == false)
        #endif
    }

    @Test func resetRefusesBeforeDeletingWhenATargetCannotBeRemoved() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("1132-preflight-\(UUID().uuidString)")
        let locked = home.appendingPathComponent("Library/Caches/us.zoom.xos/locked")
        let support = home.appendingPathComponent("Library/Application Support/zoom.us")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
        try Data("x".utf8).write(to: support.appendingPathComponent("session.db"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: home)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", ShellCommands.makeResetZoomDataCommand(homeDirectory: home.path, deletePreferencesDomain: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(fileManager.fileExists(atPath: support.appendingPathComponent("session.db").path), "deleted before refusing")
    }

    @Test func resetRemovesOnlyTheContractSet() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("1132-exact-scope-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: home) }
        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("Library/Application Support/zoom.us/data/session.db", "session")
        try write("Library/Caches/us.zoom.xos/cache.bin", "cache")
        try write("Library/Logs/zoom.us.log", "log0")
        try write("Library/Logs/zoom.us.log.1", "log1")
        for keep in ["zoom.us.log.bak", "zoom.us.logger", "Zoom.us.log.old", "other.log", "zoom.us.log.1.gz"] {
            try write("Library/Logs/\(keep)", "keep")
        }
        try fileManager.createDirectory(at: home.appendingPathComponent("Library/Logs/zoom.us.log.2"), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", ShellCommands.makeResetZoomDataCommand(homeDirectory: home.path, deletePreferencesDomain: false)]
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "reset failed: \(errText)")
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent("Library/Application Support/zoom.us").path))
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent("Library/Caches/us.zoom.xos").path))
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent("Library/Logs/zoom.us.log").path))
        #expect(!fileManager.fileExists(atPath: home.appendingPathComponent("Library/Logs/zoom.us.log.1").path))
        for keep in ["zoom.us.log.bak", "zoom.us.logger", "Zoom.us.log.old", "other.log", "zoom.us.log.1.gz", "zoom.us.log.2"] {
            #expect(fileManager.fileExists(atPath: home.appendingPathComponent("Library/Logs/\(keep)").path), "removed \(keep)")
        }
    }

    @Test func resetRefusesSymlinkedLibraryParents() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("1132-symlink-guard-\(UUID().uuidString)")
        let home = testRoot.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let outsideTarget = testRoot.appendingPathComponent("outside-caches")
        let outsideZoomCache = outsideTarget.appendingPathComponent("us.zoom.xos")
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outsideZoomCache, withIntermediateDirectories: true)
        let sentinel = outsideZoomCache.appendingPathComponent("keep.txt")
        try Data("must-not-delete".utf8).write(to: sentinel)
        try fileManager.createSymbolicLink(
            at: library.appendingPathComponent("Caches"),
            withDestinationURL: outsideTarget
        )
        defer { try? fileManager.removeItem(at: testRoot) }

        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        resetProcess.arguments = ["-c", ShellCommands.makeResetZoomDataCommand(homeDirectory: home.path, deletePreferencesDomain: false)]
        resetProcess.standardOutput = FileHandle.nullDevice
        resetProcess.standardError = FileHandle.nullDevice
        try resetProcess.run()
        resetProcess.waitUntilExit()
        #expect(resetProcess.terminationStatus != 0)
        #expect(fileManager.fileExists(atPath: sentinel.path))
    }

    @Test func launchCommandReverifiesCodesignAfterStoppingZoomAndBeforeSandboxExec() {
        let cmd = ShellCommands.makeLaunchZoomCommand(zoomBinaryExists: true)
        guard
            let stopRange = cmd.range(of: "\nstop_zoom_processes\n"),
            let codesignRange = cmd.range(of: #"/usr/bin/codesign --verify --strict -R='identifier "us.zoom.xos" and anchor apple generic and certificate leaf[subject.OU] = "BJ4HAAB9B3"' "$zoom_app""#),
            let execRange = cmd.range(of: #"/usr/bin/sandbox-exec -f "$profile_path" "$zoom_binary""#)
        else {
            Issue.record("Launch command is missing stop_zoom_processes, codesign re-verification, or sandbox-exec invocation")
            return
        }
        #expect(stopRange.lowerBound < codesignRange.lowerBound)
        #expect(codesignRange.lowerBound < execRange.lowerBound)
    }

    @Test func zoomSandboxProfileBlocksShellDotfilePersistenceAndCookiesAndTraversalHomes() {
        #expect(ShellCommands.normalizedSandboxHome("/Users/alice/..") == nil)
        #expect(ShellCommands.normalizedSandboxHome("/Users/alice/../bob") == nil)

        let profile = testProfile(home: "/Users/alice")
        #expect(profile.contains(#"(subpath "/Users/alice/Library/Cookies")"#))
        #expect(profile.contains(#"(subpath "/Users/alice/.config")"#))
        #expect(profile.contains(#"(subpath "/Users/alice/Applications")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.zshrc")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.zprofile")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.zshenv")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.bashrc")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.bash_profile")"#))
        #expect(profile.contains(#"(literal "/Users/alice/.gitconfig")"#))
    }
}
