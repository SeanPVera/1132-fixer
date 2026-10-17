import Foundation

enum DiagnosticsCollector {
    private static let commandTimeout: TimeInterval = 3
    private static let commandOutputLimit = 32 * 1_024

    static func makeSnapshot(
        executor: any ProcessExecuting = BoundedProcessExecutor()
    ) async -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let zoomAppPath = ZoomLocation.appPath
        let zoomBinaryPath = ZoomLocation.binaryPath
        let usingCustomZoomLocation = ZoomLocation.customAppPath != nil
        let zoomBundle = Bundle(path: zoomAppPath)

        // These probes are independent and read-only. Running them concurrently keeps a
        // slow system utility from serially delaying every diagnostics export.
        async let osBuild = run("/usr/bin/sw_vers", ["-buildVersion"], executor: executor)
        async let route = run("/sbin/route", ["-n", "get", "default"], executor: executor)
        async let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"], executor: executor)
        async let zoomRunning = processIsRunning("zoom.us", executor: executor)
        async let caphostRunning = processIsRunning("caphost", executor: executor)
        async let cptHostRunning = processIsRunning("CptHost", executor: executor)

        let probeResults = await (
            osBuild,
            route,
            ports,
            zoomRunning,
            caphostRunning,
            cptHostRunning
        )

        var lines = [
            "--- Environment Snapshot ---",
            "OS build: \(probeResults.0 ?? "unknown")",
            "Host architecture: \(ShellCommands.machineArchitecture())",
            "Locale: \(Locale.current.identifier)",
            "Time zone: \(TimeZone.current.identifier)",
            "Sandbox launch required: yes",
            "sandbox-exec available: \(yesNo(fileManager.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))",
            "Zoom app path: \(zoomAppPath)\(usingCustomZoomLocation ? " (custom)" : " (default)")",
            "Zoom app installed: \(yesNo(fileManager.fileExists(atPath: zoomAppPath)))",
            "Zoom binary executable: \(yesNo(fileManager.isExecutableFile(atPath: zoomBinaryPath)))",
            "Zoom version: \(zoomBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "Zoom build: \(zoomBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
            "Zoom process running: \(yesNo(probeResults.3))",
            "Zoom capture helper running: \(probeResults.4 || probeResults.5 ? "yes" : "no")",
            "MAC spoofing enabled by OS policy: \(yesNo(!ShellCommands.isMacSpoofingDisabledForCurrentOS()))",
        ]

        lines.append(contentsOf: networkSnapshot(route: probeResults.1, ports: probeResults.2))
        lines.append(contentsOf: zoomStateSnapshot(homeDirectory: home))
        return lines
    }

    private static func networkSnapshot(route: String?, ports: String?) -> [String] {
        guard let route else {
            return ["Default route: unavailable"]
        }

        do {
            let device = try ShellCommands.parseDefaultRouteInterface(from: route)
            let portName = ShellCommands.parseHardwarePorts(from: ports ?? "")[device] ?? "Unknown"
            let kind = (try? ShellCommands.classifySupportedInterface(hardwarePortName: portName))?.rawValue ?? "Unsupported"
            return [
                "Default route interface: \(device)",
                "Default route hardware port: \(portName)",
                "Default route interface type: \(kind)",
            ]
        } catch {
            return ["Default route: \(error.localizedDescription)"]
        }
    }

    private static func zoomStateSnapshot(homeDirectory: String) -> [String] {
        let paths = [
            ("Application Support", "\(homeDirectory)/Library/Application Support/zoom.us"),
            ("Cache", "\(homeDirectory)/Library/Caches/us.zoom.xos"),
            ("Preferences", "\(homeDirectory)/Library/Preferences/us.zoom.xos.plist"),
            ("Saved State", "\(homeDirectory)/Library/Saved Application State/us.zoom.xos.savedState"),
            ("Log", "\(homeDirectory)/Library/Logs/zoom.us.log"),
        ]

        return paths.map { label, path in
            "Zoom \(label) exists: \(yesNo(FileManager.default.fileExists(atPath: path)))"
        }
    }

    private static func processIsRunning(_ name: String, executor: any ProcessExecuting) async -> Bool {
        await run("/usr/bin/pgrep", ["-x", name], executor: executor) != nil
    }

    /// Runs a bounded, cancellation-aware tool directly (no shell) and returns trimmed
    /// stdout, or `nil` on timeout, launch failure, or a non-zero exit status.
    static func run(
        _ executable: String,
        _ arguments: [String],
        executor: any ProcessExecuting = BoundedProcessExecutor()
    ) async -> String? {
        do {
            let result = try await executor.run(
                executable: executable,
                arguments: arguments,
                timeout: commandTimeout,
                maxOutputBytes: commandOutputLimit
            )
            guard result.exitCode == 0 else { return nil }
            return result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// Replaces the user's home directory prefix with `~`.
    ///
    /// Diagnostics are uploaded with bug reports, and several lines embed absolute
    /// paths (the backup destination, a custom Zoom location), each of which carries
    /// the local account name. The account name has no diagnostic value.
    static func redactingHomeDirectory(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !home.isEmpty, home != "/" else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }

    static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        return "\(hours)h \(minutes)m"
    }
}
