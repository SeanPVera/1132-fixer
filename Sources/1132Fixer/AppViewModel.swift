import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppViewModel: ObservableObject {
    typealias ZoomVerifier = (_ appPath: String) async throws -> ZoomBundleVerifier.VerifiedBundle
    typealias MediaAccessChecker = () async throws -> String

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
    private static let maxInMemoryLogEntries = 2_000
    private static let maxInMemoryLogBytes = 512 * 1_024
    private static let maxSingleLogEntryBytes = 32 * 1_024

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
        case canceling
        case canceled
    }

    struct StepResult: Identifiable, Equatable {
        enum Outcome: String, Equatable {
            case success
            case warning
            case skipped
            case failed

            var label: String {
                switch self {
                case .success: return "OK"
                case .warning: return "WARN"
                case .skipped: return "SKIP"
                case .failed: return "FAIL"
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .success: return "Succeeded"
                case .warning: return "Warning"
                case .skipped: return "Skipped"
                case .failed: return "Failed"
                }
            }
        }

        let id: String
        let name: String
        let outcome: Outcome
        let detail: String?

        init(id: String, name: String, outcome: Outcome, detail: String? = nil) {
            self.id = id
            self.name = name
            self.outcome = outcome
            self.detail = detail
        }
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
            let isBlocking: Bool

            init(id: String, label: String, value: String, isWarning: Bool, isBlocking: Bool = false) {
                self.id = id
                self.label = label
                self.value = value
                self.isWarning = isWarning
                self.isBlocking = isBlocking
            }
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
            case pending, running, succeeded, warning, failed, skipped
        }
        var steps: [Step] = []
        var currentStepIndex: Int = 0
    }

    @Published var isRunning = false
    @Published var isCanceling = false
    @Published var workflowState: WorkflowState = .idle
    @Published var preflight = PreflightInfo()
    @Published var lastRunResults: [StepResult]?
    @Published var workflowProgress: WorkflowProgress?
    @Published private(set) var latestBackupPath: String? = BackupStore.latestBackupURL()?.path
    private var runningTask: Task<Void, Never>?
    private var preflightTask: Task<Void, Never>?
    private var zoomLocationSelectionTask: Task<Void, Never>?
    private var runGate = WorkflowRunGate()
    private var activePreflightID: UUID?
    private var activeZoomLocationSelectionID: UUID?
    private var retainedLogBytes = 0
    private let processExecutor: any ProcessExecuting
    private let zoomVerifier: ZoomVerifier
    private let mediaAccessChecker: MediaAccessChecker?
    private let homeDirectoryProvider: () -> String
    private let zoomLocationSetter: (String?) -> Void
    private let stopZoomCommand = ShellCommands.stopZoom
    private let stopZoomUpdatersCommand = ShellCommands.stopZoomUpdaters

    init(
        processExecutor: any ProcessExecuting = BoundedProcessExecutor(),
        zoomVerifier: @escaping ZoomVerifier = { try await ZoomBundleVerifier.verify(appPath: $0) },
        mediaAccessChecker: MediaAccessChecker? = nil,
        homeDirectoryProvider: @escaping () -> String = NSHomeDirectory,
        zoomLocationSetter: @escaping (String?) -> Void = { ZoomLocation.customAppPath = $0 }
    ) {
        self.processExecutor = processExecutor
        self.zoomVerifier = zoomVerifier
        self.mediaAccessChecker = mediaAccessChecker
        self.homeDirectoryProvider = homeDirectoryProvider
        self.zoomLocationSetter = zoomLocationSetter
    }

    /// The `zoom.us.app` bundle path currently in effect. `nil` means the default
    /// `/Applications` location; a non-nil value is a user-selected location.
    @Published var customZoomAppPath: String? = ZoomLocation.customAppPath

    /// The effective `zoom.us.app` bundle path (default or user-selected).
    var zoomAppPath: String { ZoomLocation.appPath }

    var canStartZoom: Bool {
        guard case .ready = preflight.status else { return false }
        return !preflight.checks.contains(where: \.isBlocking) && !isRunning
    }

    func startZoom() {
        guard canStartZoom else {
            appendLog("Start Zoom is unavailable until required preflight checks pass.")
            return
        }

        let requestedHomeDirectory = homeDirectoryProvider()
        let normalizedHomeDirectory = ShellCommands.normalizedSafeHomeDirectory(requestedHomeDirectory)
        let homeDirectory = normalizedHomeDirectory.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path
        } ?? requestedHomeDirectory

        lastRunResults = nil
        initProgress(steps: [
            ("validate", "Safety Check"),
            ("closeZoom", "Close Zoom"),
            ("backup", "Backup State"),
            ("network", ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network"),
            ("resetData", "Clear Local State"),
            ("dns", "DNS Flush"),
            ("updaters", "Stop Updaters"),
            ("mediaAccess", "Camera & Mic"),
            ("launch", "Launch Zoom"),
        ])
        runTask("Start Zoom") {
            var results: [StepResult] = []
            defer { self.lastRunResults = results }

            // 0. Fail fast before anything is closed or changed. This verifies both the
            // selected Zoom bundle and the exact sandbox profile used at launch time.
            self.workflowState = .preflight
            self.markStepRunning("validate")
            self.appendLog("Step: Verify Zoom signature, home directory, and required sandbox profile")
            do {
                var isDirectory: ObjCBool = false
                guard normalizedHomeDirectory != nil,
                      ShellCommands.isSafeHomeDirectory(homeDirectory),
                      FileManager.default.fileExists(atPath: homeDirectory, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw self.appError("Safety checks: refusing to continue because the home directory '\(requestedHomeDirectory)' is not a safe, existing directory.")
                }
                _ = try await self.verifiedZoomBinaryPath()
                let output = try await self.runProcess(
                    stepName: "Validate Zoom sandbox profile",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: homeDirectory)],
                    timeout: 15
                )
                self.markStepDone("validate", succeeded: true)
                results.append(.init(
                    id: "validate",
                    name: "Safety Check",
                    outcome: .success,
                    detail: output.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            } catch {
                try Task.checkCancellation()
                self.markStepDone("validate", succeeded: false)
                results.append(.init(id: "validate", name: "Safety Check", outcome: .failed, detail: error.localizedDescription))
                throw error
            }

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
                results.append(.init(id: "closeZoom", name: "Close Zoom", outcome: .success, detail: output.isEmpty ? nil : output))
            } catch {
                try Task.checkCancellation()
                self.markStepDone("closeZoom", succeeded: false)
                results.append(.init(id: "closeZoom", name: "Close Zoom", outcome: .failed, detail: error.localizedDescription))
                throw self.appError("Zoom could not be closed safely, so no backup, network, or data changes were made. \(error.localizedDescription)")
            }

            // 2. Back up Zoom state before any network mutation or deletion.
            self.workflowState = .backingUpState
            self.markStepRunning("backup")
            self.appendLog("Step: Backup Zoom local state")
            do {
                let output = try await self.runProcess(
                    stepName: "Backup Zoom state",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeBackupZoomDataCommand(homeDirectory: homeDirectory)],
                    timeout: 60
                )
                let backupPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !backupPath.isEmpty else {
                    throw self.appError("Backup completed without returning a recovery location.")
                }
                self.latestBackupPath = backupPath
                self.markStepDone("backup", succeeded: true)
                results.append(.init(id: "backup", name: "Backup State", outcome: .success, detail: "Saved to \(backupPath)"))
            } catch {
                try Task.checkCancellation()
                self.markStepDone("backup", succeeded: false)
                results.append(.init(id: "backup", name: "Backup State", outcome: .failed, detail: error.localizedDescription))
                throw self.appError("Backup failed, so no network or Zoom data changes were made. \(error.localizedDescription)")
            }

            // 3. Network handling. Failures are non-destructive warnings because the
            // private backup already exists and the remaining Zoom reset can still help.
            self.workflowState = ShellCommands.isMacSpoofingDisabledForCurrentOS() ? .checkingNetwork : .spoofingMAC
            self.markStepRunning("network")
            self.appendLog(ShellCommands.isMacSpoofingDisabledForCurrentOS()
                ? "Step: Check active network; legacy MAC spoofing is disabled on macOS 14+"
                : "Step: Spoof MAC and reconnect active network (admin prompt expected)")
            do {
                let networkResult = try await self.spoofMACAndReconnectActiveInterface()
                let outcome: StepResult.Outcome
                if networkResult.wasSkipped {
                    outcome = .skipped
                    self.markStepSkipped("network")
                } else if networkResult.hasWarning {
                    outcome = .warning
                    self.markStepWarning("network")
                } else {
                    outcome = .success
                    self.markStepDone("network", succeeded: true)
                }
                results.append(.init(
                    id: "network",
                    name: ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network",
                    outcome: outcome,
                    detail: networkResult.summary
                ))
            } catch {
                try Task.checkCancellation()
                self.markStepWarning("network")
                results.append(.init(id: "network", name: "Network Check", outcome: .warning, detail: error.localizedDescription))
                self.appendLog("Warning: Network identity was not changed: \(error.localizedDescription)")
            }

            // 4. Reset Zoom data
            self.workflowState = .clearingState
            self.markStepRunning("resetData")
            self.appendLog("Step: Reset Zoom data")
            do {
                // Runs unprivileged: every path is inside the user's own home directory.
                let output = try await self.runProcess(
                    stepName: "Reset Zoom data",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeResetZoomDataWithStatusCommand(homeDirectory: homeDirectory)]
                )
                let lines = output.components(separatedBy: .newlines)
                let resetSucceeded = lines.contains("__1132_RESET_STATUS__=0")
                let detail = lines.filter { !$0.hasPrefix("__1132_") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if resetSucceeded {
                    self.markStepDone("resetData", succeeded: true)
                } else {
                    self.markStepWarning("resetData")
                }
                results.append(.init(id: "resetData", name: "Clear Local State", outcome: resetSucceeded ? .success : .warning,
                                     detail: resetSucceeded ? (detail.isEmpty ? nil : detail) : "Could not clear all Zoom data. \(detail)"))
            } catch {
                try Task.checkCancellation()
                self.markStepWarning("resetData")
                results.append(.init(id: "resetData", name: "Clear Local State", outcome: .warning, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 5. DNS flush. macOS requests administrator privileges for this step.
            self.workflowState = .flushingDNS
            self.markStepRunning("dns")
            self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
            do {
                // The root shell cannot be killed from here, so it bounds itself just under the 60s timeout.
                let script = ShellCommands.appleScriptDoShellScript(
                    ShellCommands.makeTimeBoundedCommand(ShellCommands.makeRefreshDNSCommand(), seconds: 55),
                    administratorPrivileges: true
                )
                let output = try await self.runProcess(
                    stepName: "Refresh DNS cache",
                    executable: Constants.osascriptPath,
                    arguments: ["-e", script]
                )
                let lines = output.components(separatedBy: .newlines)
                let dnsSucceeded = lines.contains("__1132_DNS_STATUS__=0")
                let detail = lines.filter { !$0.hasPrefix("__1132_") }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if dnsSucceeded {
                    self.markStepDone("dns", succeeded: true)
                } else {
                    self.markStepWarning("dns")
                }
                results.append(.init(id: "dns", name: "DNS Flush", outcome: dnsSucceeded ? .success : .warning,
                                     detail: dnsSucceeded ? (detail.isEmpty ? nil : detail) : "Could not refresh DNS cache. \(detail)"))
            } catch {
                try Task.checkCancellation()
                self.markStepWarning("dns")
                results.append(.init(id: "dns", name: "DNS Flush", outcome: .warning, detail: error.localizedDescription))
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
                results.append(.init(id: "updaters", name: "Stop Updaters", outcome: .success, detail: output.isEmpty ? nil : output))
            } catch {
                try Task.checkCancellation()
                self.markStepWarning("updaters")
                results.append(.init(id: "updaters", name: "Stop Updaters", outcome: .warning, detail: error.localizedDescription))
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
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", outcome: .success, detail: detail))
            } catch {
                try Task.checkCancellation()
                self.markStepWarning("mediaAccess")
                results.append(.init(id: "mediaAccess", name: "Camera & Mic", outcome: .warning, detail: error.localizedDescription))
                self.appendLog("Warning: \(error.localizedDescription)")
            }

            // 8. Launch Zoom
            self.workflowState = .launchingZoom
            self.markStepRunning("launch")
            self.appendLog("Step: Launch Zoom")
            do {
                // Verify again at launch time: the location may have changed since the start of the run.
                let verifiedBinaryPath = try await self.verifiedZoomBinaryPath()
                let output = try await self.runProcess(
                    stepName: "Launch Zoom",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeLaunchZoomCommand(
                        zoomBinaryPath: verifiedBinaryPath,
                        homeDirectory: homeDirectory
                    )],
                    timeout: 120
                )
                self.markStepDone("launch", succeeded: true)
                results.append(.init(id: "launch", name: "Launch Zoom", outcome: .success, detail: output.isEmpty ? nil : output))
            } catch {
                try Task.checkCancellation()
                self.markStepDone("launch", succeeded: false)
                results.append(.init(id: "launch", name: "Launch Zoom", outcome: .failed, detail: error.localizedDescription))
                throw error // Launch failure is fatal
            }

            return WorkflowResultFormatter.summary(for: results)
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

    private func markStepWarning(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .warning
        workflowProgress = progress
    }

    private func markStepSkipped(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .skipped
        workflowProgress = progress
    }

    private func markUnfinishedStepsSkipped() {
        guard var progress = workflowProgress else { return }
        for index in progress.steps.indices {
            switch progress.steps[index].state {
            case .pending, .running:
                progress.steps[index].state = .skipped
            case .succeeded, .warning, .failed, .skipped:
                break
            }
        }
        workflowProgress = progress
    }

    func cancelWorkflow() {
        guard isRunning, !isCanceling else { return }
        isCanceling = true
        workflowState = .canceling
        appendLog("Cancel requested. Finishing the current step safely…")
        runningTask?.cancel()
    }

    func dryRun() {
        guard !isRunning else {
            appendLog("Another task is already running.")
            return
        }
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

            // Verify Zoom and the required launch profile using the same checks as a real run.
            do {
                let verified = try await self.verifiedZoomBinaryPath()
                results.append("Zoom signature: Verified")
                results.append("Zoom binary: \(verified)")
            } catch {
                try Task.checkCancellation()
                results.append("Zoom signature: FAILED — \(error.localizedDescription)")
            }

            do {
                _ = try await self.runProcess(
                    stepName: "Validate Zoom sandbox profile",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand(
                        homeDirectory: self.homeDirectoryProvider()
                    )],
                    timeout: 15
                )
                results.append("Sandbox profile: Valid")
            } catch {
                try Task.checkCancellation()
                results.append("Sandbox profile: FAILED — \(error.localizedDescription)")
            }

            if let availableBytes = BackupStore.availableCapacityBytes() {
                results.append("Backup space available: \(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file))")
            } else {
                results.append("Backup space available: Could not determine")
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
                try Task.checkCancellation()
                results.append("Network: \(error.localizedDescription)")
            }

            let camera = Self.mediaAccessPreflightValue(for: .video)
            let microphone = Self.mediaAccessPreflightValue(for: .audio)
            results.append("Camera access: \(camera.value)")
            results.append("Microphone access: \(microphone.value)")

            results.append("")
            results.append("Dry run complete. No changes were made to your system.")
            return results.joined(separator: "\n")
        }
    }

    func clearLogs() {
        logs.removeAll()
        retainedLogBytes = 0
    }

    func runPreflight() {
        preflightTask?.cancel()
        let preflightID = UUID()
        activePreflightID = preflightID
        preflight = PreflightInfo(status: .loading, checks: [])
        let selectedZoomPath = zoomAppPath
        let selectedZoomIsCustom = customZoomAppPath != nil
        let requestedHomeDirectory = homeDirectoryProvider()
        let homeDirectory = ShellCommands.normalizedSafeHomeDirectory(requestedHomeDirectory).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path
        }

        preflightTask = Task { [weak self] in
            guard let self else { return }
            var checks: [PreflightInfo.Check] = []

            // macOS version
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            let osString = "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            checks.append(.init(
                id: "os",
                label: "macOS",
                value: osString,
                isWarning: osVersion.majorVersion < 13,
                isBlocking: osVersion.majorVersion < 13
            ))

            // Architecture
            let arch = ShellCommands.machineArchitecture()
            let archLabel = arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch)
            checks.append(.init(id: "arch", label: "Architecture", value: archLabel, isWarning: false))

            var isHomeDirectory: ObjCBool = false
            let homeIsSafe = homeDirectory.map {
                ShellCommands.isSafeHomeDirectory($0)
                    && FileManager.default.fileExists(atPath: $0, isDirectory: &isHomeDirectory)
                    && isHomeDirectory.boolValue
            } ?? false
            checks.append(.init(
                id: "home",
                label: "Home Directory",
                value: homeIsSafe ? "Validated" : "Unsafe or unavailable: \(requestedHomeDirectory)",
                isWarning: !homeIsSafe,
                isBlocking: !homeIsSafe
            ))

            // Verify the selected Zoom bundle without touching it.
            do {
                _ = try await self.zoomVerifier(selectedZoomPath)
                checks.append(.init(
                    id: "zoom",
                    label: "Zoom App",
                    value: selectedZoomIsCustom ? "Verified (custom location)" : "Verified",
                    isWarning: false
                ))
            } catch {
                guard !Task.isCancelled else { return }
                checks.append(.init(
                    id: "zoom",
                    label: "Zoom App",
                    value: error.localizedDescription,
                    isWarning: true,
                    isBlocking: true
                ))
            }

            // Compile the same sandbox profile used at launch. A rejected profile is
            // blocking because the app must never fall back to an unsandboxed launch.
            do {
                guard let homeDirectory, homeIsSafe else {
                    throw self.appError("A safe home directory is required to build the Zoom sandbox profile.")
                }
                _ = try await self.runProcess(
                    stepName: "Preflight: validate sandbox",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: homeDirectory)],
                    timeout: 15
                )
                checks.append(.init(id: "sandbox", label: "Sandbox", value: "Profile validated", isWarning: false))
            } catch {
                guard !Task.isCancelled else { return }
                checks.append(.init(
                    id: "sandbox",
                    label: "Sandbox",
                    value: error.localizedDescription,
                    isWarning: true,
                    isBlocking: true
                ))
            }

            // Low space is a warning before it becomes a fail-closed backup error.
            if let availableBytes = BackupStore.availableCapacityBytes() {
                let warningThreshold: Int64 = 1_073_741_824
                let blockingThreshold: Int64 = 134_217_728
                checks.append(.init(
                    id: "storage",
                    label: "Backup Space",
                    value: "\(ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)) available",
                    isWarning: availableBytes < warningThreshold,
                    isBlocking: availableBytes < blockingThreshold
                ))
            } else {
                checks.append(.init(id: "storage", label: "Backup Space", value: "Could not determine", isWarning: true))
            }

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
                activeInterfaceKind = try ShellCommands.classifySupportedInterface(hardwarePortName: portName)

                checks.append(.init(id: "iface", label: "Active Interface", value: "\(portName) (\(device))", isWarning: false))
                checks.append(.init(id: "vpn", label: "VPN", value: "No VPN default route detected", isWarning: false))
            } catch {
                guard !Task.isCancelled else { return }
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
            if let activeInterfaceKind {
                switch ShellCommands.networkIdentityStrategy(isWiFi: activeInterfaceKind == .wifi) {
                case .rotatingPrivateWiFiAddress:
                    checks.append(.init(id: "macspoof", label: "Network Identity", value: "Rotating Private Wi-Fi Address", isWarning: false))
                case .unsupported:
                    checks.append(.init(id: "macspoof", label: "Network Identity", value: "Unavailable on this macOS/interface", isWarning: true))
                case .legacyMACSpoof:
                    checks.append(.init(id: "macspoof", label: "Network Identity", value: "MAC spoofing available", isWarning: false))
                }
            } else {
                checks.append(.init(id: "macspoof", label: "Network Identity", value: "Could not determine", isWarning: true))
            }

            let camera = Self.mediaAccessPreflightValue(for: .video)
            checks.append(.init(id: "camera", label: "Camera", value: camera.value, isWarning: camera.isWarning))
            let microphone = Self.mediaAccessPreflightValue(for: .audio)
            checks.append(.init(id: "microphone", label: "Microphone", value: microphone.value, isWarning: microphone.isWarning))

            guard self.activePreflightID == preflightID, !Task.isCancelled else { return }
            self.preflight = PreflightInfo(status: .ready, checks: checks)
            self.preflightTask = nil
        }
    }

    private static func mediaAccessPreflightValue(for mediaType: AVMediaType) -> (value: String, isWarning: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return ("Allowed", false)
        case .notDetermined:
            return ("Will request access when needed", true)
        case .denied:
            return ("Denied in System Settings", true)
        case .restricted:
            return ("Restricted by macOS or device management", true)
        @unknown default:
            return ("Unknown", true)
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.diagnosticsFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let diagnostics = await makeDiagnosticsExport(appVersion: appVersion)
            do {
                try await Task.detached(priority: .utility) {
                    try diagnostics.content.write(to: url, atomically: true, encoding: .utf8)
                }.value
                appendLog("Diagnostics exported to \(url.lastPathComponent)")
            } catch {
                appendLog("Failed to export diagnostics: \(error.localizedDescription)")
            }
        }
    }

    func makeBugReportDraft(appVersion: String) async -> BugReportDraft {
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
        let diagnostics = await makeDiagnosticsExport(
            appVersion: appVersion,
            maxLogLines: Self.maxInMemoryLogEntries
        )
        return BugReportDraft(
            title: title,
            systemInfo: systemInfo,
            diagnosticsFileName: diagnostics.fileName,
            diagnosticsData: Data(diagnostics.content.utf8)
        )
    }

    private func makeDiagnosticsExport(appVersion: String, maxLogLines: Int? = nil) async -> (fileName: String, content: String) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let stepResults = lastRunResults
        let preflightChecks = preflight.checks
        let capturedLogs = maxLogLines.map { Array(logs.suffix($0)) } ?? logs
        let environmentSnapshot = await DiagnosticsCollector.makeSnapshot(executor: processExecutor)

        var lines: [String] = []
        lines.append("1132 Fixer Diagnostics Report")
        lines.append("Generated: \(timestamp)")
        lines.append("App version: \(appVersion)")
        lines.append("OS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("Last action status: \(lastStatus)")
        lines.append("")
        lines.append(contentsOf: environmentSnapshot)
        lines.append("")

        if let results = stepResults {
            lines.append("--- Step Results ---")
            for step in results {
                lines.append("[\(step.outcome.label)] \(step.name)\(step.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }

        if !preflightChecks.isEmpty {
            lines.append("--- Preflight Checks ---")
            for check in preflightChecks {
                let mark = check.isBlocking ? "x" : (check.isWarning ? "!" : "+")
                lines.append("[\(mark)] \(check.label): \(check.value)")
            }
            lines.append("")
        }

        lines.append("--- Activity Log (\(capturedLogs.count) entries) ---")
        lines.append(contentsOf: capturedLogs)

        // This content is uploaded with bug reports, so strip the local account name.
        let content = DiagnosticsCollector.redactingHomeDirectory(lines.joined(separator: "\n"))
        return (Self.diagnosticsFileName, content)
    }

    private func runTask(
        _ title: String,
        action: @escaping () async throws -> String
    ) {
        guard !isRunning else {
            appendLog("Another task is already running.")
            return
        }

        guard let runID = runGate.begin() else {
            appendLog("Another task still owns the workflow lock.")
            return
        }
        isRunning = true
        isCanceling = false
        let clock = ContinuousClock()
        let startedAt = clock.now
        appendLog("=== \(title) ===")

        runningTask = Task {
            defer {
                if runGate.finish(runID) {
                    appendLog("Timing: \(title) finished in \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
                    isRunning = false
                    isCanceling = false
                    runningTask = nil
                    runPreflight()
                }
            }
            do {
                try Task.checkCancellation()
                let output = try await action()
                try Task.checkCancellation()
                if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendLog(output)
                }
                workflowState = .completed
                appendLog("=== Completed ===")
            } catch is CancellationError {
                workflowState = .canceled
                markUnfinishedStepsSkipped()
                appendLog("=== Canceled safely ===")
            } catch {
                if Task.isCancelled {
                    workflowState = .canceled
                    markUnfinishedStepsSkipped()
                    appendLog("=== Canceled safely ===")
                    return
                }
                workflowState = .failed(error.localizedDescription)
                markUnfinishedStepsSkipped()
                appendLog("Error: \(error.localizedDescription)")
                appendLog("=== Failed ===")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let boundedText = Self.tailLimitedUTF8(text, maxBytes: Self.maxSingleLogEntryBytes)
        let entry = "[\(timestamp)] \(boundedText)"
        logs.append(entry)
        retainedLogBytes += entry.utf8.count

        while logs.count > Self.maxInMemoryLogEntries || retainedLogBytes > Self.maxInMemoryLogBytes {
            guard !logs.isEmpty else { break }
            retainedLogBytes -= logs.removeFirst().utf8.count
        }
    }

    private static func tailLimitedUTF8(_ value: String, maxBytes: Int) -> String {
        let data = Data(value.utf8)
        guard data.count > maxBytes else { return value }

        let note = Data("[earlier text truncated]\n".utf8)
        var tail = data.suffix(max(maxBytes - note.count, 0))
        while let first = tail.first, first & 0xC0 == 0x80 {
            tail = tail.dropFirst()
        }
        return String(decoding: note + tail, as: UTF8.self)
    }

    private static func formatElapsed(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.2fs", seconds)
    }

    private func inferLastActionStatus() -> String {
        for line in logs.reversed() {
            if line.contains("=== Failed ===") {
                return "Error"
            }
            if line.contains("=== Completed ===") {
                return "Completed"
            }
            if line.contains("=== Canceled safely ===") {
                return "Canceled"
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
                hasWarning: true,
                wasSkipped: true
            )
        case .legacyMACSpoof:
            break
        }

        let spoofedMAC = try ShellCommands.generateRandomMACAddress()
        let spoofScript = ShellCommands.makeSpoofCommand(device: interface.device, spoofedMAC: spoofedMAC, networkService: interface.networkService)

        appendLog("Network recovery: commands to be attempted on \(interface.device) (service: \(interface.networkService))")

        // The root shell cannot be killed from here, so it bounds itself just under the 90s timeout below.
        let appleScript = ShellCommands.appleScriptDoShellScript(
            ShellCommands.makeTimeBoundedCommand(spoofScript, seconds: 85),
            administratorPrivileges: true
        )
        let commandOutput: String
        do {
            commandOutput = try await runProcess(
                stepName: "Spoof MAC and reconnect \(interface.kind.rawValue)",
                executable: Constants.osascriptPath,
                arguments: ["-e", appleScript],
                timeout: 90
            )
        } catch {
            try Task.checkCancellation()
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
        let actualMACOutput = (try? await runProcess(
            stepName: "Verify MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        )) ?? ""
        try Task.checkCancellation()
        let actualMAC = ShellCommands.normalizedMACAddress(actualMACOutput)
        let macVerified = actualMAC == spoofedMAC.lowercased()

        var warnings: [String] = []
        let summary: String
        if macVerified {
            summary = "MAC spoofed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.map {
                "Current MAC (\($0)) does not match target (\(spoofedMAC))."
            } ?? "Could not read the current MAC address after spoofing."
            appendLog("Network recovery: MAC change was not applied. Commands attempted:")
            appendLog("  \(spoofScript)")
            let warning = """
Warning: MAC address was not changed on \(interface.kind.rawValue) (\(interface.device)). \(detail)
This is a known macOS limitation on Apple Silicon Macs (macOS Sonoma 14 and later):
the OS blocks Wi-Fi MAC spoofing at the driver level. Zoom will likely still show error 1132.
What you can try:
  1. Connect via Ethernet — MAC spoofing still works on Ethernet adapters.
  2. Use your phone as a hotspot — this gives you a different network identity entirely.
  3. Turn on Private Wi-Fi Address for your network in System Settings > Wi-Fi,
disconnect, and reconnect before running Start Zoom again.
If your network connection is disrupted after this step:
  - Open System Settings > Network and toggle '\(interface.networkService)' off then on
  - Or run in Terminal: sudo /sbin/ifconfig \(interface.device) up
"""
            warnings.append(warning)
            summary = warning
        }

        let recoveryWarning = try await verifyNetworkRecovered(expectedDevice: interface.device)
        if let recoveryWarning {
            warnings.append(recoveryWarning)
        }

        let trimmedCommandOutput = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var summaryParts = [summary]

        if !trimmedCommandOutput.isEmpty {
            summaryParts.append(trimmedCommandOutput)
        }
        for warning in warnings where warning != summary {
            summaryParts.append(warning)
        }
        let combinedSummary = summaryParts.joined(separator: "\n")

        return MACSpoofResult(
            summary: combinedSummary,
            hasWarning: !warnings.isEmpty,
            wasSkipped: false
        )
    }

    private func resetPrivateWiFiAddressAndReconnect(networkService: String, device: String) async throws -> MACSpoofResult {
        let verifyScript = ShellCommands.makeVerifyMACCommand(device: device)
        let previousMACOutput = (try? await runProcess(
            stepName: "Read current MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        )) ?? ""
        let previousMAC = ShellCommands.normalizedMACAddress(previousMACOutput)
        try Task.checkCancellation()

        // 1. Check current private address mode
        let getModeCmd = ShellCommands.makeGetPrivateAddressModeCommand(networkService: networkService)
        let currentModeOutput = (try? await runProcess(
            stepName: "Check Private Wi-Fi Address mode",
            executable: Constants.bashPath,
            arguments: ["-c", getModeCmd]
        )) ?? "unsupported"
        try Task.checkCancellation()
        let currentMode = ShellCommands.normalizePrivateAddressModeOutput(currentModeOutput)

        appendLog("Private Wi-Fi Address mode: \(currentMode)")

        var modeWasChanged = false
        var warnings: [String] = []

        // 2. If not rotating, set it
        if currentMode == "unsupported" {
            warnings.append("Warning: Private Wi-Fi Address controls are unsupported on this macOS/networksetup version.")
        } else if currentMode != "rotating" {
            let setModeCmd = ShellCommands.makeSetPrivateAddressModeCommand(networkService: networkService, mode: "rotating")
            let setModeScript = ShellCommands.appleScriptDoShellScript(
                ShellCommands.makeTimeBoundedCommand(setModeCmd, seconds: 10),
                administratorPrivileges: true
            )
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
                try Task.checkCancellation()
                let warning = "Warning: Could not set Private Wi-Fi Address to rotating: \(error.localizedDescription)"
                warnings.append(warning)
                appendLog(warning)
            }
        }

        // 3. Cycle the interface to generate a new MAC — always brings it back up
        let resetCmd = ShellCommands.makeRotatingMACResetCommand(device: device)
        let resetScript = ShellCommands.appleScriptDoShellScript(
            ShellCommands.makeTimeBoundedCommand(resetCmd, seconds: 25),
            administratorPrivileges: true
        )
        do {
            _ = try await runProcess(
                stepName: "Reset Wi-Fi to generate new rotating MAC",
                executable: Constants.osascriptPath,
                arguments: ["-e", resetScript],
                timeout: 30
            )
        } catch {
            try Task.checkCancellation()
            let warning = "Warning: Wi-Fi cycle encountered an error: \(error.localizedDescription)"
            warnings.append(warning)
            appendLog(warning)
            // Interface was already brought back up by the command — log and continue
        }

        // 4. Read the new MAC for logging
        let newMACOutput = (try? await runProcess(
            stepName: "Read new MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        )) ?? ""
        let newMAC = ShellCommands.normalizedMACAddress(newMACOutput)
        try Task.checkCancellation()

        let verifiedModeOutput = (try? await runProcess(
            stepName: "Verify Private Wi-Fi Address mode",
            executable: Constants.bashPath,
            arguments: ["-c", getModeCmd]
        )) ?? "unsupported"
        try Task.checkCancellation()
        let verifiedMode = ShellCommands.normalizePrivateAddressModeOutput(verifiedModeOutput)

        if verifiedMode != "rotating" {
            warnings.append("Warning: Private Wi-Fi Address mode is '\(verifiedMode)' after the change; rotating mode was not verified.")
        }
        if newMAC == nil {
            warnings.append("Warning: The current MAC address could not be read after cycling Wi-Fi.")
        } else if let previousMAC, newMAC == previousMAC {
            warnings.append("Warning: Wi-Fi reconnected, but the MAC address did not change (\(previousMAC)).")
        }
        let recoveryWarning = try await verifyNetworkRecovered(expectedDevice: device)
        if let recoveryWarning {
            warnings.append(recoveryWarning)
        }

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

        let displayedMAC = newMAC ?? "(could not read)"
        var summaryParts = ["\(modeNote)Wi-Fi cycled for a rotating MAC. Current MAC: \(displayedMAC)"]
        summaryParts.append(contentsOf: warnings)

        return MACSpoofResult(
            summary: summaryParts.joined(separator: "\n"),
            hasWarning: !warnings.isEmpty,
            wasSkipped: false
        )
    }

    private func verifyNetworkRecovered(expectedDevice: String) async throws -> String? {
        do {
            _ = try await runProcess(
                stepName: "Verify network recovery",
                executable: Constants.bashPath,
                arguments: ["-c", ShellCommands.makeNetworkReadinessCommand(device: expectedDevice)],
                timeout: 20
            )
            return nil
        } catch {
            try Task.checkCancellation()
            return "Warning: The network did not regain a verified default route: \(error.localizedDescription)"
        }
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

    // MARK: - Zoom Location

    /// Prompts the user to choose a `zoom.us.app` bundle when Zoom is installed
    /// outside the default location. Sandbox-mode launch is unchanged; only the
    /// bundle location is configurable.
    /// Verifies the Zoom bundle currently in effect (name, symlinks and code signature) off
    /// the main actor and returns the verified, symlink-resolved executable path. Called
    /// before any destructive step and again right before launch, because the custom
    /// location lives in `UserDefaults` and can change at any time.
    private func verifiedZoomBinaryPath() async throws -> String {
        let appPath = zoomAppPath
        let verified = try await zoomVerifier(appPath)
        return verified.binaryPath
    }

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

        cancelPendingZoomLocationSelection()
        let selectedPath = url.path
        guard let validated = ZoomLocation.validatedAppPath(selectedPath) else {
            appendLog("Selected app is not a valid Zoom installation: \(selectedPath)")
            workflowState = .failed("The selected app does not contain the Zoom executable. Choose 'zoom.us.app'.")
            return
        }

        verifyAndSelectZoomLocation(validated)
    }

    /// Verifies and applies a structurally valid Zoom bundle selected by the user.
    /// Only the newest request may update the stored path or surface an error.
    func verifyAndSelectZoomLocation(_ validated: String) {
        cancelPendingZoomLocationSelection()
        let selectionID = UUID()
        activeZoomLocationSelectionID = selectionID

        zoomLocationSelectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await zoomVerifier(validated)
                try Task.checkCancellation()
                guard activeZoomLocationSelectionID == selectionID else { return }

                finishZoomLocationSelection(selectionID)
                zoomLocationSetter(validated)
                customZoomAppPath = validated
                appendLog("Zoom location set to: \(validated)")
                runPreflight()
            } catch is CancellationError {
                finishZoomLocationSelection(selectionID)
            } catch {
                guard activeZoomLocationSelectionID == selectionID else { return }
                finishZoomLocationSelection(selectionID)
                appendLog("Selected app was rejected: \(error.localizedDescription)")
                workflowState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelPendingZoomLocationSelection() {
        activeZoomLocationSelectionID = nil
        zoomLocationSelectionTask?.cancel()
        zoomLocationSelectionTask = nil
    }

    private func finishZoomLocationSelection(_ selectionID: UUID) {
        guard activeZoomLocationSelectionID == selectionID else { return }
        activeZoomLocationSelectionID = nil
        zoomLocationSelectionTask = nil
    }

    /// Reverts to the default `/Applications/zoom.us.app` location.
    func resetZoomLocation() {
        cancelPendingZoomLocationSelection()
        zoomLocationSetter(nil)
        customZoomAppPath = nil
        appendLog("Zoom location reset to default: \(ZoomLocation.defaultAppPath)")
        runPreflight()
    }

    func revealLatestBackup() {
        let candidate = latestBackupPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BackupStore.latestBackupURL()
        guard let candidate, BackupStore.isManagedBackupURL(candidate) else {
            latestBackupPath = nil
            appendLog("No managed Zoom backup is available to reveal.")
            return
        }

        latestBackupPath = candidate.path
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }

    /// How long to wait for an answer to a camera/microphone prompt before
    /// giving up on it and continuing to the Zoom launch.
    private static let mediaAccessPromptTimeout: TimeInterval = 60

    private struct MediaAccessResult {
        let isGranted: Bool
        let message: String
    }

    private func ensureMediaAccessForSandboxedZoom() async throws -> String {
        if let mediaAccessChecker {
            return try await mediaAccessChecker()
        }

        // macOS only presents a privacy prompt while the requesting app is
        // frontmost. The admin (SecurityAgent) prompts in the earlier steps leave
        // another process in front, so without this the prompt is deferred and
        // the step waits on a dialog the user never gets to answer.
        await bringAppToFront()

        // Both media types are always evaluated: a camera problem must not skip
        // the microphone request, otherwise the microphone stays "not determined"
        // and every later run stops at the same never-shown prompt.
        let camera = await ensureMediaAccess(
            mediaType: .video,
            displayName: "Camera",
            usageDescriptionKey: "NSCameraUsageDescription"
        )
        let microphone = await ensureMediaAccess(
            mediaType: .audio,
            displayName: "Microphone",
            usageDescriptionKey: "NSMicrophoneUsageDescription"
        )

        let results = [camera, microphone]
        let summary = results.map(\.message).joined(separator: "; ")
        guard results.allSatisfy(\.isGranted) else {
            throw appError(summary)
        }
        return summary
    }

    private func ensureMediaAccess(
        mediaType: AVMediaType,
        displayName: String,
        usageDescriptionKey: String
    ) async -> MediaAccessResult {
        let settingsHint = "Open System Settings > Privacy & Security > \(displayName), enable 1132 Fixer, then run Start Zoom again."

        guard Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) != nil else {
            return MediaAccessResult(
                isGranted: false,
                message: "\(displayName) access cannot be requested because \(usageDescriptionKey) is missing from the app bundle."
            )
        }

        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return MediaAccessResult(isGranted: true, message: "\(displayName) access already granted")
        case .notDetermined:
            let timeoutSeconds = Int(Self.mediaAccessPromptTimeout)
            appendLog("Waiting for the macOS \(displayName) prompt — click Allow (continuing without it after \(timeoutSeconds)s).")
            switch await requestMediaAccess(for: mediaType) {
            case .answered(let granted):
                guard granted else {
                    return MediaAccessResult(isGranted: false, message: "\(displayName) access was denied. \(settingsHint)")
                }
                return MediaAccessResult(isGranted: true, message: "\(displayName) access granted")
            case .unanswered:
                return MediaAccessResult(
                    isGranted: false,
                    message: "\(displayName) prompt went unanswered for \(timeoutSeconds)s. If no prompt appeared: \(settingsHint)"
                )
            }
        case .denied:
            return MediaAccessResult(isGranted: false, message: "\(displayName) access is denied. \(settingsHint)")
        case .restricted:
            return MediaAccessResult(isGranted: false, message: "\(displayName) access is restricted by macOS or device management policy.")
        @unknown default:
            return MediaAccessResult(isGranted: false, message: "\(displayName) access is in an unknown authorization state.")
        }
    }

    /// Requests access to `mediaType`, giving up once the prompt has gone
    /// unanswered for `mediaAccessPromptTimeout` seconds.
    ///
    /// `AVCaptureDevice.requestAccess` has no timeout of its own: when macOS
    /// never shows the prompt, its completion handler is never called and the
    /// workflow would wait forever with nothing on screen to click. The timeout
    /// keeps the step moving — camera/mic denial is already non-fatal, so Zoom
    /// still launches and the 1132 fix still applies.
    private func requestMediaAccess(for mediaType: AVMediaType) async -> MediaAccessOutcome {
        // Never raise a new prompt for a workflow the user already canceled.
        guard !Task.isCancelled else { return .unanswered }

        let waiter = MediaAccessWaiter()

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.mediaAccessPromptTimeout)
        timer.setEventHandler { waiter.finish(.unanswered) }
        timer.resume()

        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            timer.cancel()
            waiter.finish(.answered(granted))
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
                waiter.attach(continuation)
            }
        } onCancel: {
            timer.cancel()
            waiter.finish(.unanswered)
        }
    }

    /// Makes 1132 Fixer the frontmost app so macOS presents its privacy prompts
    /// instead of deferring them behind whatever ran last.
    private func bringAppToFront() async {
        let app = NSApplication.shared
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
        app.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)

        // Activation is asynchronous; let it land before asking for the prompt.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func appError(_ message: String) -> AppError {
        AppError.general(message)
    }

    /// Runs a process through the shared bounded executor and returns its combined output.
    ///
    /// Privileged AppleScript commands are awaited in a detached task so canceling the UI
    /// workflow cannot release the single-flight lock while a self-bounded root shell may
    /// still be finishing.
    private func runProcess(
        stepName: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> String {
        try Task.checkCancellation()

        let clock = ContinuousClock()
        let startedAt = clock.now
        defer {
            appendLog("Timing: \(stepName) took \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
        }

        do {
            let result: ProcessExecutionResult
            if executable == Constants.osascriptPath {
                let executor = processExecutor
                result = try await Task.detached(priority: .userInitiated) {
                    try await executor.run(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        maxOutputBytes: BoundedProcessExecutor.defaultMaxOutputBytes
                    )
                }.value
            } else {
                result = try await processExecutor.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    maxOutputBytes: BoundedProcessExecutor.defaultMaxOutputBytes
                )
            }
            try Task.checkCancellation()

            let output = result.combinedOutput
            guard result.exitCode == 0 else {
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let message: String
                if !trimmedOutput.isEmpty {
                    message = "\(stepName): \(trimmedOutput)"
                } else if executable == Constants.osascriptPath {
                    message = "\(stepName): Admin authorization was canceled or failed. This step requires your macOS password to run with elevated privileges. Click Start Zoom again and enter your password when prompted."
                } else {
                    message = "\(stepName): Command failed with exit code \(result.exitCode)."
                }
                throw AppError.processFailed(exitCode: Int(result.exitCode), message: message)
            }
            return output
        } catch let error as ProcessExecutionError {
            if case .timedOut = error {
                appendLog("Timeout: '\(stepName)' did not complete within \(Int(timeout))s — terminated.")
                throw AppError.processTimeout("\(stepName): Timed out after \(Int(timeout)) seconds.")
            }
            throw error
        }
    }

}

/// The result of a single `AVCaptureDevice.requestAccess` call.
enum MediaAccessOutcome: Equatable {
    /// The user answered the macOS privacy prompt.
    case answered(Bool)
    /// No answer arrived: the prompt was never shown, was left open past the
    /// timeout, or the workflow was canceled while waiting.
    case unanswered
}

/// Bridges `AVCaptureDevice.requestAccess` to `async`/`await` so that whichever
/// comes first — the user's answer, the timeout, or workflow cancellation —
/// resumes the caller exactly once. Later outcomes are discarded, and an outcome
/// that lands before the caller starts awaiting is buffered.
final class MediaAccessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaAccessOutcome, Never>?
    private var outcome: MediaAccessOutcome?

    /// Records the first outcome and hands it to the waiting caller, if any.
    func finish(_ outcome: MediaAccessOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(returning: outcome)
    }

    /// Suspends the caller until `finish` is called, or resumes it immediately
    /// when an outcome has already been recorded.
    func attach(_ continuation: CheckedContinuation<MediaAccessOutcome, Never>) {
        lock.lock()
        if let outcome = self.outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}
