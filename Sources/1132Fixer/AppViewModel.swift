import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppViewModel: ObservableObject {
    struct BugReportDraft {
        let title: String
        let systemInfo: String
        let diagnosticsFileName: String
        let diagnosticsData: Data
    }

    private struct NetworkInterfaceInfo {
        enum Kind: String {
            case wifi = "Wi-Fi"
            case ethernet = "Ethernet"
        }

        let device: String
        let hardwarePort: String
        let networkService: String
        let kind: Kind
    }

    private struct MACSpoofResult {
        let summary: String
        let hasWarning: Bool
        let wasSkipped: Bool
    }

    private enum Constants {
        static let errorDomain = "1132Fixer"
        static let bashPath = ShellCommands.bashPath
        static let osascriptPath = ShellCommands.osascriptPath
    }

    private final class LockedDataBuffer {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    private static let logTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()
    private static let bugTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
    private static let diagnosticsFileName = "1132Fixer-diagnostics.txt"

    enum WorkflowState: Equatable {
        case idle
        case preflight
        case closingZoom
        case spoofingMAC
        case checkingNetwork
        case backingUpState
        case clearingState
        case flushingDNS
        case stoppingUpdaters
        case checkingMediaAccess
        case launchingZoom
        case completed
        case failed(String)
        case canceled
    }

    struct StepResult: Identifiable, Equatable {
        let id: String
        let name: String
        let succeeded: Bool
        let detail: String?
    }

    struct PreflightInfo: Equatable {
        enum Status: Equatable {
            case loading
            case ready
            case error(String)
        }

        struct Check: Identifiable, Equatable {
            let id: String
            let label: String
            let value: String
            let isWarning: Bool
        }

        var status: Status = .loading
        var checks: [Check] = []
    }

    @Published var logs: [String] = []
    struct WorkflowProgress: Equatable {
        struct Step: Identifiable, Equatable {
            let id: String
            let name: String
            var state: StepState
        }
        enum StepState: Equatable {
            case pending, running, succeeded, failed, skipped
        }
        var steps: [Step] = []
        var currentStepIndex: Int = 0
    }

    @Published var isRunning = false
    @Published var workflowState: WorkflowState = .idle
    @Published var preflight = PreflightInfo()
    @Published var lastRunResults: [StepResult]?
    @Published var workflowProgress: WorkflowProgress?
    private var runningTask: Task<Void, Never>?
    private var currentProcess: Process?
    private let stopZoomCommand = ShellCommands.stopZoom
    private let stopZoomUpdatersCommand = ShellCommands.stopZoomUpdaters
    private let refreshDNSAppleScript = ShellCommands.refreshDNSAppleScript

    /// The `zoom.us.app` bundle path currently in effect. `nil` means the default
    /// `/Applications` location; a non-nil value is a user-selected location.
    @Published var customZoomAppPath: String? = ZoomLocation.customAppPath

    /// The effective Zoom executable path (default or user-selected).
    private var zoomBinaryPath: String { ZoomLocation.binaryPath }

    /// The effective `zoom.us.app` bundle path (default or user-selected).
    var zoomAppPath: String { ZoomLocation.appPath }

    func startZoom() {
        lastRunResults = nil
        initProgress(steps: [
            ("closeZoom", "Close Zoom"),
            ("network", ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network"),
            ("backup", "Backup State"),
            ("resetData", "Clear Local State"),
            ("dns", "DNS Flush"),
            ("updaters", "Stop Updaters"),
            ("mediaAccess", "Camera & Mic"),
            ("launch", "Launch Zoom"),
        ])
        runTask("Start Zoom") {
            var results: [StepResult] = []

            // 1. Close Zoom
            self.workflowState = .closingZoom
            self.markStepRunning("closeZoom")
            self.appendLog("Step: Close Zoom if it is running")
            do {
                let output = try await self.runProcess(
                    stepName: "Close Zoom",
                    executable: Constants.bashPath,
                    arguments: ["-c", self.stopZoomCommand]
                )
                self.markStepDone("closeZoom", succeeded: true)
                results.append(.init(id: "closeZoom", name: "Close Zoom", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("closeZoom", succeeded: false)
                results.append(.init(id: "closeZoom", name: "Close Zoom", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 2. Network handling
            self.workflowState = ShellCommands.isMacSpoofingDisabledForCurrentOS() ? .checkingNetwork : .spoofingMAC
            self.markStepRunning("network")
            self.appendLog(ShellCommands.isMacSpoofingDisabledForCurrentOS()
                ? "Step: Check active network; MAC spoofing is disabled on macOS 14+"
                : "Step: Spoof MAC and reconnect active network (admin prompt expected)")
            let macSpoofResult: MACSpoofResult
            do {
                macSpoofResult = try await self.spoofMACAndReconnectActiveInterface()
                if macSpoofResult.wasSkipped {
                    self.markStepSkipped("network")
                } else {
                    self.markStepDone("network", succeeded: !macSpoofResult.hasWarning)
                }
                results.append(.init(
                    id: "network",
                    name: ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network",
                    succeeded: !macSpoofResult.hasWarning,
                    detail: macSpoofResult.summary
                ))
            } catch {
                macSpoofResult = MACSpoofResult(summary: "Network step skipped: \(error.localizedDescription)", hasWarning: true, wasSkipped: true)
                self.markStepDone("network", succeeded: false)
                results.append(.init(id: "network", name: "Network Check", succeeded: false, detail: error.localizedDescription))
            }

            // 3. Backup Zoom state
            self.workflowState = .backingUpState
            self.markStepRunning("backup")
            self.appendLog("Step: Backup Zoom local state")
            do {
                let output = try await self.runProcess(
                    stepName: "Backup Zoom state",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeBackupZoomDataCommand()],
                    timeout: 30
                )
                let backupPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.markStepDone("backup", succeeded: true)
                results.append(.init(id: "backup", name: "Backup State", succeeded: true, detail: backupPath.isEmpty ? nil : "Saved to \(backupPath)"))
            } catch {
                self.markStepDone("backup", succeeded: false)
                results.append(.init(id: "backup", name: "Backup State", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: Backup failed, continuing anyway: \(error.localizedDescription)")
            }

            // 4. Reset Zoom data
            self.workflowState = .clearingState
            self.markStepRunning("resetData")
            self.appendLog("Step: Reset Zoom data")
            do {
                let resetCommand = ShellCommands.makeResetZoomDataCommand(homeDirectory: NSHomeDirectory())
                let resetScript = ShellCommands.appleScriptDoShellScript(resetCommand, administratorPrivileges: true)
                let output = try await self.runProcess(
                    stepName: "Reset Zoom data",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", resetScript]
                )
                self.markStepDone("resetData", succeeded: true)
                results.append(.init(id: "resetData", name: "Clear Local State", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("resetData", succeeded: false)
                results.append(.init(id: "resetData", name: "Clear Local State", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 5. DNS flush
            self.workflowState = .flushingDNS
            self.markStepRunning("dns")
            self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
            do {
                let output = try await self.runProcess(
                    stepName: "Refresh DNS cache",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", self.refreshDNSAppleScript]
                )
                self.markStepDone("dns", succeeded: true)
                results.append(.init(id: "dns", name: "DNS Flush", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("dns", succeeded: false)
                results.append(.init(id: "dns", name: "DNS Flush", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 6. Stop updaters
            self.workflowState = .stoppingUpdaters
            self.markStepRunning("updaters")
            self.appendLog("Step: Stop Zoom updaters")
            do {
                let output = try await self.runProcess(
                    stepName: "Stop Zoom updaters",
                    executable: Constants.bashPath,
                    arguments: ["-c", self.stopZoomUpdatersCommand]
                )
                self.markStepDone("updaters", succeeded: true)
                results.append(.init(id: "updaters", name: "Stop Updaters", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("updaters", succeeded: false)
                results.append(.init(id: "updaters", name: "Stop Updaters", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 7. Ensure camera and microphone access before the sandboxed launch.
            // Zoom runs under sandbox-exec, so macOS attributes Zoom's camera/mic
            // TCC requests to this app (the launcher). This app must therefore hold
            // the grants for Zoom to see the camera/mic. Denial is non-fatal: Zoom
            // still launches so the 1132 fix proceeds; only A/V is affected.
            self.workflowState = .checkingMediaAccess
            self.markStepRunning("mediaAccess")
            self.appendLog("Step: Check camera and microphone access")
            do {
                let detail = try await self.ensureMediaAccessForSandboxedZoom()
                self.markStepDone("mediaAccess", succeeded: true)
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", succeeded: true, detail: detail))
            } catch {
                self.markStepDone("mediaAccess", succeeded: false)
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", succeeded: false, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 8. Launch Zoom
            self.workflowState = .launchingZoom
            self.markStepRunning("launch")
            self.appendLog("Step: Launch Zoom")
            do {
                let output = try await self.runProcess(
                    stepName: "Launch Zoom",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: self.zoomBinaryPath)],
                    timeout: 120
                )
                self.markStepDone("launch", succeeded: true)
                results.append(.init(id: "launch", name: "Launch Zoom", succeeded: true, detail: output.isEmpty ? nil : output))
            } catch {
                self.markStepDone("launch", succeeded: false)
                results.append(.init(id: "launch", name: "Launch Zoom", succeeded: false, detail: error.localizedDescription))
                throw error // Launch failure is fatal
            }

            self.lastRunResults = results

            let allSucceeded = results.allSatisfy(\.succeeded)
            let failedSteps = results.filter { !$0.succeeded }.map(\.name)
            let summaryParts = results.map { step in
                "\(step.succeeded ? "OK" : "WARN") \(step.name)\(step.detail.map { ": \($0.prefix(80))" } ?? "")"
            }

            let header = allSucceeded
                ? "All steps completed successfully."
                : "Completed with warnings: \(failedSteps.joined(separator: ", "))"

            return header + "\n" + summaryParts
                .joined(separator: "\n")
        }
    }

    private func initProgress(steps: [(id: String, name: String)]) {
        workflowProgress = WorkflowProgress(
            steps: steps.map { .init(id: $0.id, name: $0.name, state: .pending) },
            currentStepIndex: 0
        )
    }

    private func markStepRunning(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .running
        progress.currentStepIndex = idx
        workflowProgress = progress
    }

    private func markStepDone(_ id: String, succeeded: Bool) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = succeeded ? .succeeded : .failed
        workflowProgress = progress
    }

    private func markStepSkipped(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .skipped
        workflowProgress = progress
    }

    func cancelWorkflow() {
        runningTask?.cancel()
        currentProcess?.terminate()
        workflowState = .canceled
        appendLog("Workflow canceled by user.")
        isRunning = false
    }

    func dryRun() {
        lastRunResults = nil
        workflowProgress = nil
        runTask("Dry Run") {
            var results: [String] = []

            // Check macOS version
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            results.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

            // Check architecture
            let arch = ShellCommands.machineArchitecture()
            results.append("Architecture: \(arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch))")

            // Check Zoom
            let zoomInstalled = FileManager.default.fileExists(atPath: self.zoomBinaryPath)
            results.append("Zoom binary: \(zoomInstalled ? "Found" : "NOT FOUND") at \(self.zoomBinaryPath)")
            if self.customZoomAppPath != nil {
                results.append("Zoom location: Custom (\(self.zoomAppPath))")
            }

            let zoomRunning = (try? await self.runProcess(
                stepName: "Check Zoom process",
                executable: Constants.bashPath,
                arguments: ["-c", "/usr/bin/pgrep -x \"zoom.us\" >/dev/null 2>&1 && echo running || echo stopped"]
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            results.append("Zoom process: \(zoomRunning)")

            // Check network interface
            do {
                let routeOutput = try await self.runProcess(
                    stepName: "Detect interface",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/sbin/route -n get default 2>/dev/null"]
                )
                let device = try ShellCommands.parseDefaultRouteInterface(from: routeOutput)

                let portsOutput = try await self.runProcess(
                    stepName: "Hardware ports",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
                )
                let portMap = ShellCommands.parseHardwarePorts(from: portsOutput)
                let portName = portMap[device] ?? "Unknown"
                results.append("Active interface: \(portName) (\(device))")

                if let kind = try? ShellCommands.classifySupportedInterface(hardwarePortName: portName) {
                    results.append("Interface type: \(kind.rawValue)")
                    switch ShellCommands.networkIdentityStrategy(isWiFi: kind == .wifi) {
                    case .rotatingPrivateWiFiAddress:
                        results.append("Network identity: Rotating Private Wi-Fi Address (Apple Silicon + macOS 14+)")
                    case .unsupported:
                        results.append("Network identity: UNAVAILABLE — MAC spoofing is disabled on macOS 14+")
                    case .legacyMACSpoof:
                        results.append("Network identity: MAC spoofing available")
                    }
                }
            } catch {
                results.append("Network: \(error.localizedDescription)")
            }

            results.append("")
            results.append("Dry run complete. No changes were made to your system.")
            return results.joined(separator: "\n")
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func runPreflight() {
        preflight = PreflightInfo(status: .loading, checks: [])
        Task {
            var checks: [PreflightInfo.Check] = []

            // macOS version
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            checks.append(.init(id: "os", label: "macOS", value: osString, isWarning: osVersion.majorVersion < 13))

            // Architecture
            let arch = ShellCommands.machineArchitecture()
            let archLabel = arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch)
            checks.append(.init(id: "arch", label: "Architecture", value: archLabel, isWarning: false))

            // Zoom installed
            let zoomInstalled = FileManager.default.fileExists(atPath: zoomBinaryPath)
            let zoomValue: String
            if zoomInstalled {
                zoomValue = customZoomAppPath != nil ? "Installed (custom location)" : "Installed"
            } else {
                zoomValue = "Not found"
            }
            checks.append(.init(id: "zoom", label: "Zoom App", value: zoomValue, isWarning: !zoomInstalled))

            // Active interface & VPN
            var activeInterfaceKind: ShellCommands.InterfaceKind?
            do {
                let routeOutput = try await runProcess(
                    stepName: "Preflight: detect interface",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/sbin/route -n get default 2>/dev/null"]
                )
                let device = try ShellCommands.parseDefaultRouteInterface(from: routeOutput)

                let portsOutput = try await runProcess(
                    stepName: "Preflight: hardware ports",
                    executable: Constants.bashPath,
                    arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
                )
                let portMap = ShellCommands.parseHardwarePorts(from: portsOutput)
                let portName = portMap[device] ?? "Unknown"
                activeInterfaceKind = try? ShellCommands.classifySupportedInterface(hardwarePortName: portName)

                checks.append(.init(id: "iface", label: "Active Interface", value: "\(portName) (\(device))", isWarning: false))
                checks.append(.init(id: "vpn", label: "VPN", value: "Not detected", isWarning: false))
            } catch {
                let msg = error.localizedDescription
                if msg.contains("VPN detected") {
                    checks.append(.init(id: "vpn", label: "VPN", value: "Active (turn off before running)", isWarning: true))
                } else {
                    checks.append(.init(id: "iface", label: "Active Interface", value: "Could not detect", isWarning: true))
                }
            }

            // Admin prompts expected (DNS flush needs admin; MAC spoofing on supported macOS also needs admin)
            checks.append(.init(id: "admin", label: "Admin Prompts", value: "Expected", isWarning: false))

            // How the workflow can change network identity on this OS and interface.
            switch ShellCommands.networkIdentityStrategy(isWiFi: activeInterfaceKind == .wifi) {
            case .rotatingPrivateWiFiAddress:
                checks.append(.init(id: "macspoof", label: "Network Identity", value: "Rotating Private Wi-Fi Address", isWarning: false))
            case .unsupported:
                checks.append(.init(id: "macspoof", label: "Network Identity", value: "Unavailable — MAC spoofing is disabled on macOS 14+", isWarning: true))
            case .legacyMACSpoof:
                checks.append(.init(id: "macspoof", label: "Network Identity", value: "MAC spoofing available", isWarning: false))
            }

            preflight = PreflightInfo(status: .ready, checks: checks)
        }
    }

    func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs.joined(separator: "\n"), forType: .string)
    }

    func logMessage(_ text: String) {
        appendLog(text)
    }

    func exportDiagnostics(appVersion: String) {
        let diagnostics = makeDiagnosticsExport(appVersion: appVersion)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = diagnostics.fileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnostics.content.write(to: url, atomically: true, encoding: .utf8)
            appendLog("Diagnostics exported to \(url.lastPathComponent)")
        } catch {
            appendLog("Failed to export diagnostics: \(error.localizedDescription)")
        }
    }

    func makeBugReportDraft(appVersion: String) -> BugReportDraft {
        let now = Date()
        let title = "Bug Report \(Self.bugTitleFormatter.string(from: now))"
        let timestamp = Self.logTimestampFormatter.string(from: now)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let systemInfo = """
App version: \(appVersion)
OS: \(osVersion)
Architecture: \(architecture)
Timestamp: \(timestamp)
Last action status: \(lastStatus)
"""
        let diagnostics = makeDiagnosticsExport(appVersion: appVersion)
        return BugReportDraft(
            title: title,
            systemInfo: systemInfo,
            diagnosticsFileName: diagnostics.fileName,
            diagnosticsData: Data(diagnostics.content.utf8)
        )
    }

    private func makeDiagnosticsExport(appVersion: String, maxLogLines: Int? = nil) -> (fileName: String, content: String) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let timestamp = Self.logTimestampFormatter.string(from: Date())

        var lines: [String] = []
        lines.append("1132 Fixer Diagnostics Report")
        lines.append("Generated: \(timestamp)")
        lines.append("App version: \(appVersion)")
        lines.append("OS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("Last action status: \(lastStatus)")
        lines.append("")
        lines.append(contentsOf: DiagnosticsCollector.makeSnapshot())
        lines.append("")

        if let results = lastRunResults {
            lines.append("--- Step Results ---")
            for step in results {
                let mark = step.succeeded ? "OK" : "WARN"
                lines.append("[\(mark)] \(step.name)\(step.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }

        if !preflight.checks.isEmpty {
            lines.append("--- Preflight Checks ---")
            for check in preflight.checks {
                let mark = check.isWarning ? "!" : "+"
                lines.append("[\(mark)] \(check.label): \(check.value)")
            }
            lines.append("")
        }

        let logLines: [String]
        if let maxLogLines {
            logLines = Array(logs.suffix(maxLogLines))
        } else {
            logLines = logs
        }

        lines.append("--- Activity Log (\(logLines.count) entries) ---")
        lines.append(contentsOf: logLines)

        return (Self.diagnosticsFileName, lines.joined(separator: "\n"))
    }

    private func runTask(
        _ title: String,
        action: @escaping () async throws -> String
    ) {
        guard !isRunning else {
            appendLog("Another task is already running.")
            return
        }

        isRunning = true
        appendLog("=== \(title) ===")

        runningTask = Task {
            defer {
                isRunning = false
                runningTask = nil
                currentProcess = nil
            }
            do {
                try Task.checkCancellation()
                let output = try await action()
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog(output)
                }
                workflowState = .completed
                appendLog("=== Completed ===")
            } catch is CancellationError {
                workflowState = .canceled
                appendLog("=== Canceled ===")
            } catch {
                workflowState = .failed(error.localizedDescription)
                appendLog("Error: \(error.localizedDescription)")
                appendLog("=== Failed ===")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logs.append("[\(timestamp)] \(text)")
    }

    private func inferLastActionStatus() -> String {
        for line in logs.reversed() {
            if line.contains("=== Failed ===") {
                return "Error"
            }
            if line.contains("=== Completed ===") {
                return "Completed"
            }
            if line.contains("=== Start Zoom ===") {
                return "In Progress"
            }
        }
        return "Unknown"
    }


    private func spoofMACAndReconnectActiveInterface() async throws -> MACSpoofResult {
        let interface = try await resolveActiveSupportedInterface()

        switch ShellCommands.networkIdentityStrategy(isWiFi: interface.kind == .wifi) {
        case .rotatingPrivateWiFiAddress:
            return try await resetPrivateWiFiAddressAndReconnect(networkService: interface.networkService, device: interface.device)
        case .unsupported:
            return MACSpoofResult(
                summary: "MAC spoofing is disabled on macOS 14 and later because the old spoofing method no longer works reliably. Active network: \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)).",
                hasWarning: false,
                wasSkipped: true
            )
        case .legacyMACSpoof:
            break
        }

        let spoofedMAC = try ShellCommands.generateRandomMACAddress()
        let spoofScript = ShellCommands.makeSpoofCommand(device: interface.device, spoofedMAC: spoofedMAC, networkService: interface.networkService)

        appendLog("Network recovery: commands to be attempted on \(interface.device) (service: \(interface.networkService))")

        let appleScript = ShellCommands.appleScriptDoShellScript(spoofScript, administratorPrivileges: true)
        let commandOutput: String
        do {
            commandOutput = try await runProcess(
                stepName: "Spoof MAC and reconnect \(interface.kind.rawValue)",
                executable: Constants.osascriptPath,
                arguments: ["-e", appleScript],
                timeout: 90
            )
        } catch {
            // Network step failed midway — log the exact commands and provide recovery
            appendLog("Network recovery: MAC spoof command failed. Commands attempted:")
            appendLog("  \(spoofScript)")
            appendLog("""
Network recovery: Your network interface may be in an inconsistent state. To restore manually:
  1. Open System Settings > Network
  2. Find '\(interface.networkService)' and turn it off, then on again
  3. Or run in Terminal: sudo /sbin/ifconfig \(interface.device) up
  4. If Wi-Fi is disconnected, click the Wi-Fi menu and reconnect to your network
""")
            throw error
        }

        let verifyScript = ShellCommands.makeVerifyMACCommand(device: interface.device)
        let actualMAC = (try? await runProcess(
            stepName: "Verify MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let macVerified = !actualMAC.isEmpty && actualMAC == spoofedMAC.lowercased()

        let summary: String
        if macVerified {
            summary = "MAC spoofed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.isEmpty
                ? "Could not read the current MAC address after spoofing."
                : "Current MAC (\(actualMAC)) does not match target (\(spoofedMAC))."
            appendLog("Network recovery: MAC change was not applied. Commands attempted:")
            appendLog("  \(spoofScript)")
            summary = """
Warning: MAC address was not changed on \(interface.kind.rawValue) (\(interface.device)). \(detail)
This is a known macOS limitation on Apple Silicon Macs (macOS Sonoma 14 and later): \
the OS blocks Wi-Fi MAC spoofing at the driver level. Zoom will likely still show error 1132.
What you can try:
  1. Connect via Ethernet — MAC spoofing still works on Ethernet adapters.
  2. Use your phone as a hotspot — this gives you a different network identity entirely.
  3. Turn on Private Wi-Fi Address for your network in System Settings > Wi-Fi, \
disconnect, and reconnect before running Start Zoom again.
If your network connection is disrupted after this step:
  - Open System Settings > Network and toggle '\(interface.networkService)' off then on
  - Or run in Terminal: sudo /sbin/ifconfig \(interface.device) up
"""
        }

        let trimmedCommandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedSummary: String

        if trimmedCommandOutput.isEmpty {
            combinedSummary = summary
        } else {
            combinedSummary = "\(summary)\n\(trimmedCommandOutput)"
        }

        return MACSpoofResult(
            summary: combinedSummary,
            hasWarning: combinedSummary.contains("Warning:"),
            wasSkipped: false
        )
    }

    private func resetPrivateWiFiAddressAndReconnect(networkService: String, device: String) async throws -> MACSpoofResult {
        // 1. Check current private address mode
        let getModeCmd = ShellCommands.makeGetPrivateAddressModeCommand(networkService: networkService)
        let currentModeOutput = (try? await runProcess(
            stepName: "Check Private Wi-Fi Address mode",
            executable: Constants.bashPath,
            arguments: ["-c", getModeCmd]
        )) ?? "unsupported"
        let currentMode = ShellCommands.normalizePrivateAddressModeOutput(currentModeOutput)

        appendLog("Private Wi-Fi Address mode: \(currentMode)")

        var modeWasChanged = false
        var warnings: [String] = []

        // 2. If not rotating, set it
        if currentMode == "unsupported" {
            warnings.append("Warning: Private Wi-Fi Address controls are unsupported on this macOS/networksetup version.")
        } else if currentMode != "rotating" {
            let setModeCmd = ShellCommands.makeSetPrivateAddressModeCommand(networkService: networkService, mode: "rotating")
            let setModeScript = ShellCommands.appleScriptDoShellScript(setModeCmd, administratorPrivileges: true)
            do {
                _ = try await runProcess(
                    stepName: "Enable rotating Private Wi-Fi Address",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", setModeScript],
                    timeout: 15
                )
                modeWasChanged = true
                appendLog("Private Wi-Fi Address set to rotating (was: \(currentMode))")
            } catch {
                let warning = "Warning: Could not set Private Wi-Fi Address to rotating: \(error.localizedDescription)"
                warnings.append(warning)
                appendLog(warning)
            }
        }

        // 3. Cycle the interface to generate a new MAC — always brings it back up
        let resetCmd = ShellCommands.makeRotatingMACResetCommand(device: device)
        let resetScript = ShellCommands.appleScriptDoShellScript(resetCmd, administratorPrivileges: true)
        do {
            _ = try await runProcess(
                stepName: "Reset Wi-Fi to generate new rotating MAC",
                executable: Constants.osascriptPath,
                arguments: ["-e", resetScript],
                timeout: 30
            )
        } catch {
            let warning = "Warning: Wi-Fi cycle encountered an error: \(error.localizedDescription)"
            warnings.append(warning)
            appendLog(warning)
            // Interface was already brought back up by the command — log and continue
        }

        // 4. Read the new MAC for logging
        let verifyScript = ShellCommands.makeVerifyMACCommand(device: device)
        let newMAC = (try? await runProcess(
            stepName: "Read new MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(could not read)"

        let modeNote: String
        if currentMode == "unsupported" {
            modeNote = "Private Wi-Fi Address mode could not be verified on this system. "
        } else if modeWasChanged {
            modeNote = "Private Wi-Fi Address changed to rotating (was: \(currentMode)). "
        } else if currentMode == "rotating" {
            modeNote = "Private Wi-Fi Address was already set to rotating. "
        } else {
            modeNote = "Private Wi-Fi Address remained \(currentMode). "
        }

        var summaryParts = ["\(modeNote)Wi-Fi cycled to generate new rotating MAC. Current MAC: \(newMAC)"]
        summaryParts.append(contentsOf: warnings)

        return MACSpoofResult(
            summary: summaryParts.joined(separator: "\n"),
            hasWarning: !warnings.isEmpty,
            wasSkipped: false
        )
    }

    private func resolveActiveSupportedInterface() async throws -> NetworkInterfaceInfo {
        let defaultRouteOutput = try await runProcess(
            stepName: "Detect active network interface",
            executable: Constants.bashPath,
            arguments: ["-c", "/sbin/route -n get default"]
        )
        let activeDevice = try ShellCommands.parseDefaultRouteInterface(from: defaultRouteOutput)

        let hardwarePortsOutput = try await runProcess(
            stepName: "Inspect hardware ports",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listallhardwareports"]
        )
        let hardwarePortMap = ShellCommands.parseHardwarePorts(from: hardwarePortsOutput)

        guard let hardwarePortName = hardwarePortMap[activeDevice] else {
            throw appError("Detect active network interface: Could not map interface '\(activeDevice)' to a hardware port.")
        }

        let scKind = try ShellCommands.classifySupportedInterface(hardwarePortName: hardwarePortName)
        let kind: NetworkInterfaceInfo.Kind = scKind == .wifi ? .wifi : .ethernet

        let serviceOrderOutput = try await runProcess(
            stepName: "Inspect network services",
            executable: Constants.bashPath,
            arguments: ["-c", "/usr/sbin/networksetup -listnetworkserviceorder"]
        )
        let serviceMap = ShellCommands.parseNetworkServiceOrder(from: serviceOrderOutput)

        guard let networkService = serviceMap[activeDevice], !networkService.isEmpty else {
            throw appError("Detect active network interface: Could not resolve network service for interface '\(activeDevice)'. This can happen if the interface was renamed in System Settings or if a third-party network tool is managing your connection. Check System Settings > Network and ensure your connection is listed.")
        }

        return NetworkInterfaceInfo(
            device: activeDevice,
            hardwarePort: hardwarePortName,
            networkService: networkService,
            kind: kind
        )
    }

    private func makeLaunchZoomCommand() -> String {
        ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: zoomBinaryPath)
    }

    // MARK: - Zoom Location

    /// Prompts the user to choose a `zoom.us.app` bundle when Zoom is installed
    /// outside the default location. Sandbox-mode launch is unchanged; only the
    /// bundle location is configurable.
    func chooseZoomLocation() {
        let panel = NSOpenPanel()
        panel.title = "Select Zoom Application"
        panel.message = "Choose the Zoom app (zoom.us.app) if it is installed outside the default Applications folder."
        panel.prompt = "Select"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let selectedPath = url.path
        guard let validated = ZoomLocation.validatedAppPath(selectedPath) else {
            appendLog("Selected app is not a valid Zoom installation: \(selectedPath)")
            workflowState = .failed("The selected app does not contain the Zoom executable. Choose 'zoom.us.app'.")
            return
        }

        ZoomLocation.customAppPath = validated
        customZoomAppPath = validated
        appendLog("Zoom location set to: \(validated)")
        runPreflight()
    }

    /// Reverts to the default `/Applications/zoom.us.app` location.
    func resetZoomLocation() {
        ZoomLocation.customAppPath = nil
        customZoomAppPath = nil
        appendLog("Zoom location reset to default: \(ZoomLocation.defaultAppPath)")
        runPreflight()
    }

    private func ensureMediaAccessForSandboxedZoom() async throws -> String {
        let cameraStatus = try await ensureMediaAccess(
            mediaType: .video,
            displayName: "Camera",
            usageDescriptionKey: "NSCameraUsageDescription"
        )
        let microphoneStatus = try await ensureMediaAccess(
            mediaType: .audio,
            displayName: "Microphone",
            usageDescriptionKey: "NSMicrophoneUsageDescription"
        )

        return "\(cameraStatus); \(microphoneStatus)"
    }

    private func ensureMediaAccess(
        mediaType: AVMediaType,
        displayName: String,
        usageDescriptionKey: String
    ) async throws -> String {
        guard Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil else {
            throw appError("\(displayName) access cannot be requested because \(usageDescriptionKey) is missing from the app bundle.")
        }

        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return "\(displayName) access already granted"
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            if granted {
                return "\(displayName) access granted"
            }
            throw appError("\(displayName) access was denied. Enable 1132 Fixer in System Settings > Privacy & Security > \(displayName), then run Start Zoom again.")
        case .denied:
            throw appError("\(displayName) access is denied. Enable 1132 Fixer in System Settings > Privacy & Security > \(displayName), then run Start Zoom again.")
        case .restricted:
            throw appError("\(displayName) access is restricted by macOS or device management policy.")
        @unknown default:
            throw appError("\(displayName) access is in an unknown authorization state.")
        }
    }

    private func appError(_ message: String) -> AppError {
        AppError.general(message)
    }

    private final class ContinuationResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false

        func beginResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }

    private func runProcess(stepName: String, executable: String, arguments: [String], timeout: TimeInterval = 60) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        currentProcess = process

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuffer = LockedDataBuffer()
            let stderrBuffer = LockedDataBuffer()
            let resumeGate = ContinuationResumeGate()

            @Sendable func safeResume(_ result: Result<String, Error>) {
                guard resumeGate.beginResume() else { return }
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutBuffer.append(chunk)
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrBuffer.append(chunk)
            }

            // Timeout timer
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
                DispatchQueue.main.async {
                    self.appendLog("Timeout: '\(stepName)' did not complete within \(Int(timeout))s — terminating.")
                }
                safeResume(.failure(AppError.processTimeout("\(stepName): Timed out after \(Int(timeout)) seconds.")))
            }
            timer.resume()

            do {
                process.terminationHandler = { terminatedProcess in
                    timer.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    let outData = stdoutBuffer.snapshot()
                    let errData = stderrBuffer.snapshot()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let combined = [stdout, stderr]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")

                    if terminatedProcess.terminationStatus == 0 {
                        safeResume(.success(combined))
                        return
                    }

                    let trimmedOutput = combined.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message: String
                    if !trimmedOutput.isEmpty {
                        message = "\(stepName): \(trimmedOutput)"
                    } else if executable == Constants.osascriptPath {
                        message = "\(stepName): Admin authorization was canceled or failed. This step requires your macOS password to run with elevated privileges. Click Start Zoom again and enter your password when prompted."
                    } else {
                        message = "\(stepName): Command failed with exit code \(terminatedProcess.terminationStatus)."
                    }

                    safeResume(.failure(AppError.processFailed(
                        exitCode: Int(terminatedProcess.terminationStatus),
                        message: message
                    )))
                }

                try process.run()
            } catch {
                timer.cancel()
                safeResume(.failure(error))
            }
        }
    }

}
