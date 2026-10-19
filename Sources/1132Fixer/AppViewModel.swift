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

    typealias ProcessExecutor = @Sendable (
        _ stepName: String,
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) async throws -> String

    typealias BundleVerifier = @Sendable (_ appPath: String) throws -> ZoomBundleVerifier.VerifiedBundle

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

    enum Constants {
        static let errorDomain = "1132Fixer"
        static let bashPath = ShellCommands.bashPath
        static let osascriptPath = ShellCommands.osascriptPath
    }

    private final class LockedDataBuffer: @unchecked Sendable {
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

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            let snapshot = value
            lock.unlock()
            return snapshot
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
    static let diagnosticsFileName = "1132Fixer-diagnostics.txt"
    static let maxInMemoryLogEntries = 5_000

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
            case interrupted
            case unstarted
            case running

            static let succeeded: Outcome = .success

            var label: String {
                switch self {
                case .success: return "OK"
                case .warning: return "WARN"
                case .skipped: return "SKIP"
                case .failed: return "FAIL"
                case .interrupted: return "STOP"
                case .unstarted: return "PEND"
                case .running: return "RUN"
                }
            }

            var displayLabel: String {
                switch self {
                case .success: return "Succeeded"
                case .warning: return "Warning"
                case .skipped: return "Skipped"
                case .failed: return "Failed"
                case .interrupted: return "Stopped"
                case .unstarted: return "Not run"
                case .running: return "Running"
                }
            }

            var accessibilityLabel: String {
                displayLabel
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

    struct WorkflowProgress: Equatable {
        struct Step: Identifiable, Equatable {
            let id: String
            let name: String
            var state: StepState
        }
        enum StepState: Equatable {
            case unstarted
            case running
            case succeeded
            case warning
            case failed
            case skipped
            case interrupted

            static let pending: StepState = .unstarted
        }
        var steps: [Step] = []
        var currentStepIndex: Int = 0
    }

    @Published var logs: [String] = []
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var logRevision: UInt64 = 0

    @Published var isRunning = false
    @Published var isCanceling = false
    @Published private(set) var isExecutingPrivilegedStep = false
    @Published var workflowState: WorkflowState = .idle
    @Published var preflight = PreflightInfo() {
        didSet {
            readinessSnapshot = ReadinessSnapshot.from(
                preflight: preflight,
                selectedAppPath: zoomAppPath,
                isCustomLocation: customZoomAppPath != nil,
                checkedAt: Date()
            )
        }
    }
    @Published private(set) var readinessSnapshot: ReadinessSnapshot
    @Published var lastRunResults: [StepResult]?
    @Published var workflowProgress: WorkflowProgress?
    @Published private(set) var currentRunRecord: RunRecord?

    /// Non-nil ONLY when the latest run created a verified backup in Step 3.
    @Published private(set) var currentRunBackupPath: String?
    /// Non-nil when an older managed backup exists on disk from a prior run.
    @Published private(set) var previousBackupPath: String?
    /// Combined backup path for callers that reveal whichever managed backup is available.
    @Published private(set) var latestBackupPath: String?

    // Sheet and workspace presentation state owned by the model so views stay macro-free and testable.
    @Published var activeRepairPlan: RepairPlan?
    @Published var isShowingSystemChecksSheet = false
    @Published var isShowingActivityLogSheet = false
    @Published var isFollowingLatestLog = true
    @Published var activeReportDraft: ReportDraft?
    @Published var isPreparingReportDraft = false
    @Published var isAttachmentPreviewExpanded = true
    @Published var expandedStepIDs: Set<String> = []
    @Published var installationNotice: String?

    @Published var updateAlertIsPresented = false
    @Published var latestRelease: ReleaseInfo?
    @Published var isReportingBug = false
    @Published var bugReportEmail = ""
    @Published var bugReportMessage = ""
    @Published var bugReportError: String?

    // Optional test overrides for deterministic unit testing.
    var processExecutorOverride: ProcessExecutor?
    var bundleVerifierOverride: BundleVerifier?
    var availableBackupCapacityBytesOverride: (() -> Int64?)?
    var skipBringAppToFront = false

    private var runningTask: Task<Void, Never>?
    private var preflightTask: Task<Void, Never>?
    private var runGate = WorkflowRunGate()
    private var activePreflightID: UUID?
    private let stopZoomCommand = ShellCommands.stopZoom
    private let stopZoomUpdatersCommand = ShellCommands.stopZoomUpdaters

    /// The `zoom.us.app` bundle path currently in effect. `nil` means the default
    /// `/Applications` location; a non-nil value is a user-selected location.
    @Published var customZoomAppPath: String? = ZoomLocation.customAppPath

    /// The effective `zoom.us.app` bundle path (default or user-selected).
    var zoomAppPath: String {
        customZoomAppPath ?? ZoomLocation.appPath
    }

    var isOperationGateActive: Bool {
        runGate.isActive
    }

    var canStartZoom: Bool {
        guard case .ready = preflight.status else { return false }
        return !preflight.checks.contains(where: \.isBlocking) && !isRunning && !runGate.isActive
    }

    init(initialDiskBackupPath: String? = BackupStore.latestBackupURL()?.path) {
        let initialCustomPath = ZoomLocation.customAppPath
        let initialEffectivePath = initialCustomPath ?? ZoomLocation.appPath
        self.customZoomAppPath = initialCustomPath
        self.readinessSnapshot = .initial(
            selectedAppPath: initialEffectivePath,
            isCustomLocation: initialCustomPath != nil
        )
        self.currentRunBackupPath = nil
        self.previousBackupPath = initialDiskBackupPath
        self.latestBackupPath = initialDiskBackupPath
    }

    // MARK: - Plan & Sheet Presentation

    func prepareAndPresentRepairPlan() {
        guard canStartZoom else {
            appendLog("Repair review is unavailable until required system checks pass.")
            return
        }
        activeRepairPlan = RepairPlan.build(
            readiness: readinessSnapshot,
            selectedAppPath: zoomAppPath,
            isCustomLocation: customZoomAppPath != nil
        )
    }

    func dismissRepairPlan() {
        activeRepairPlan = nil
    }

    func confirmRepairPlanAndStart() {
        activeRepairPlan = nil
        startZoom()
    }

    func toggleStepExpansion(_ stepID: String) {
        if expandedStepIDs.contains(stepID) {
            expandedStepIDs.remove(stepID)
        } else {
            expandedStepIDs.insert(stepID)
        }
    }

    func openBugReportSheet(appVersion: String) {
        guard activeReportDraft == nil, !isPreparingReportDraft else { return }
        bugReportError = nil
        isPreparingReportDraft = true
        Task {
            let draft = await makeReportDraft(appVersion: appVersion)
            self.activeReportDraft = draft
            self.isPreparingReportDraft = false
        }
    }

    func closeBugReportSheet() {
        guard !isReportingBug else { return }
        activeReportDraft = nil
        bugReportError = nil
    }

    func submitBugReport() async {
        guard !isReportingBug, let draft = activeReportDraft else { return }

        let trimmedMessage = bugReportMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            bugReportError = "Add a short description before sending the report."
            return
        }
        if bugReportMessage.count > ReportDraft.maxDescriptionCharacters {
            let excess = bugReportMessage.count - ReportDraft.maxDescriptionCharacters
            bugReportError = "Shorten your description by \(excess) \(excess == 1 ? "character" : "characters") before sending."
            return
        }

        isReportingBug = true
        bugReportError = nil
        defer { isReportingBug = false }

        appendLog("=== Report a Bug ===")
        let trimmedEmail = bugReportEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await BugReportService.sendBugReport(
                title: draft.title,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: trimmedMessage,
                systemInfo: draft.systemInfo,
                diagnosticsFileName: draft.diagnosticsFileName,
                diagnosticsData: draft.attachmentData
            )
            appendLog("Bug report submitted successfully.")
            activeReportDraft = nil
            bugReportEmail = ""
            bugReportMessage = ""
        } catch {
            let message = error.localizedDescription
            bugReportError = message
            appendLog("Bug report failed: \(message)")
        }
    }

    func checkForUpdates(appVersion: String) async {
        guard appVersion != "dev",
              latestRelease == nil,
              ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"] == nil else {
            return
        }

        do {
            let release = try await UpdateChecker.fetchLatestRelease()
            if UpdateChecker.isUpdateAvailable(currentVersion: appVersion, latestVersion: release.version) {
                latestRelease = release
                updateAlertIsPresented = true
            }
        } catch {
            // Update checks are advisory and must never block app usage.
        }
    }

    // MARK: - Primary Repair Workflow

    func startZoom() {
        guard canStartZoom else {
            appendLog("Start Zoom is unavailable until required preflight checks pass.")
            return
        }

        let canonicalSpecs = RepairStepSpec.canonicalSteps()
        let stepPairs = canonicalSpecs.map { ($0.id, $0.name) }

        // If a previous run created a backup, demote it to previousBackupPath before starting this run.
        if let priorRunBackup = currentRunBackupPath {
            previousBackupPath = priorRunBackup
        }
        currentRunBackupPath = nil
        latestBackupPath = previousBackupPath
        lastRunResults = nil
        expandedStepIDs.removeAll()
        initProgress(steps: stepPairs)

        let initialSteps = canonicalSpecs.map {
            StepResult(id: $0.id, name: $0.name, outcome: .unstarted, detail: $0.plannedSummary)
        }
        let runRecordID = UUID()
        let selectedPath = zoomAppPath
        currentRunRecord = RunRecord(
            id: runRecordID,
            title: "Repair Zoom 1132",
            startedAt: Date(),
            finishedAt: nil,
            selectedAppPath: selectedPath,
            outcome: .running,
            steps: initialSteps,
            createdBackupPath: nil,
            failureMessage: nil,
            failedStepID: nil
        )

        runTask("Start Zoom") {
            var completedResults: [StepResult] = []
            var activeStepSpec: RepairStepSpec?
            var runCreatedBackup: String?

            @MainActor
            func syncRunRecord(outcome: RunRecord.Outcome, failureMessage: String? = nil, failedStepID: String? = nil) {
                var merged: [StepResult] = []
                for spec in canonicalSpecs {
                    if let finished = completedResults.first(where: { $0.id == spec.id }) {
                        merged.append(finished)
                    } else if activeStepSpec?.id == spec.id && (outcome == .running || outcome == .stopping) {
                        merged.append(StepResult(id: spec.id, name: spec.name, outcome: .running, detail: spec.plannedSummary))
                    } else {
                        merged.append(StepResult(id: spec.id, name: spec.name, outcome: .unstarted, detail: "Not run"))
                    }
                }
                self.lastRunResults = merged
                self.currentRunRecord = RunRecord(
                    id: runRecordID,
                    title: "Repair Zoom 1132",
                    startedAt: self.currentRunRecord?.startedAt ?? Date(),
                    finishedAt: (outcome == .running || outcome == .stopping) ? nil : Date(),
                    selectedAppPath: selectedPath,
                    outcome: outcome,
                    steps: merged,
                    createdBackupPath: runCreatedBackup,
                    failureMessage: failureMessage,
                    failedStepID: failedStepID
                )
            }

            @MainActor
            func beginStep(_ id: String) {
                activeStepSpec = canonicalSpecs.first(where: { $0.id == id })
                self.markStepRunning(id)
                syncRunRecord(outcome: self.isCanceling ? .stopping : .running)
            }

            @MainActor
            func finishStep(_ result: StepResult) {
                completedResults.removeAll(where: { $0.id == result.id })
                completedResults.append(result)
                if activeStepSpec?.id == result.id {
                    activeStepSpec = nil
                }
                if result.outcome == .failed || result.outcome == .warning {
                    self.expandedStepIDs.insert(result.id)
                }
                syncRunRecord(outcome: self.isCanceling ? .stopping : .running)
            }

            do {
                // 1. Fail fast before anything is closed or changed.
                self.workflowState = .preflight
                beginStep("validate")
                self.appendLog("Step: Verify Zoom signature and required sandbox profile")
                do {
                    _ = try await self.verifiedZoomBinaryPath()
                    let output = try await self.runProcess(
                        stepName: "Validate Zoom sandbox profile",
                        executable: Constants.bashPath,
                        arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand()],
                        timeout: 15
                    )
                    self.markStepDone("validate", succeeded: true)
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishStep(.init(
                        id: "validate",
                        name: "Safety Check",
                        outcome: .success,
                        detail: trimmed.isEmpty ? "Verified signature and compiled sandbox launch profile." : trimmed
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepDone("validate", succeeded: false)
                    finishStep(.init(id: "validate", name: "Safety Check", outcome: .failed, detail: error.localizedDescription))
                    throw error
                }

                // 2. Close Zoom
                self.workflowState = .closingZoom
                beginStep("closeZoom")
                self.appendLog("Step: Close Zoom if it is running")
                do {
                    let output = try await self.runProcess(
                        stepName: "Close Zoom",
                        executable: Constants.bashPath,
                        arguments: ["-c", self.stopZoomCommand]
                    )
                    self.markStepDone("closeZoom", succeeded: true)
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishStep(.init(
                        id: "closeZoom",
                        name: "Close Zoom",
                        outcome: .success,
                        detail: trimmed.isEmpty ? "Zoom processes closed cleanly." : trimmed
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepDone("closeZoom", succeeded: false)
                    finishStep(.init(id: "closeZoom", name: "Close Zoom", outcome: .failed, detail: error.localizedDescription))
                    throw self.appError("Zoom could not be closed safely, so no backup, network, or data changes were made. \(error.localizedDescription)")
                }

                // 3. Back up Zoom state before any network mutation or deletion.
                self.workflowState = .backingUpState
                beginStep("backup")
                self.appendLog("Step: Backup Zoom local state")
                do {
                    let output = try await self.runProcess(
                        stepName: "Backup Zoom state",
                        executable: Constants.bashPath,
                        arguments: ["-c", ShellCommands.makeBackupZoomDataCommand()],
                        timeout: 60
                    )
                    let backupPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !backupPath.isEmpty else {
                        throw self.appError("Backup completed without returning a recovery location.")
                    }
                    runCreatedBackup = backupPath
                    self.currentRunBackupPath = backupPath
                    self.latestBackupPath = backupPath
                    self.markStepDone("backup", succeeded: true)
                    finishStep(.init(id: "backup", name: "Backup State", outcome: .success, detail: "Saved to \(backupPath)"))
                } catch {
                    try Task.checkCancellation()
                    self.markStepDone("backup", succeeded: false)
                    finishStep(.init(id: "backup", name: "Backup State", outcome: .failed, detail: error.localizedDescription))
                    throw self.appError("Backup failed, so no network or Zoom data changes were made. \(error.localizedDescription)")
                }

                // 4. Network handling.
                let networkStepName = ShellCommands.isMacSpoofingDisabledForCurrentOS() ? "Network Check" : "MAC Spoof & Network"
                self.workflowState = ShellCommands.isMacSpoofingDisabledForCurrentOS() ? .checkingNetwork : .spoofingMAC
                beginStep("network")
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
                    finishStep(.init(
                        id: "network",
                        name: networkStepName,
                        outcome: outcome,
                        detail: networkResult.summary
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepWarning("network")
                    finishStep(.init(id: "network", name: networkStepName, outcome: .warning, detail: error.localizedDescription))
                    self.appendLog("Warning: Network identity was not changed: \(error.localizedDescription)")
                }

                // 5. Reset Zoom data
                self.workflowState = .clearingState
                beginStep("resetData")
                self.appendLog("Step: Reset Zoom data")
                do {
                    let home = NSHomeDirectory()
                    guard ShellCommands.isSafeHomeDirectory(home) else {
                        throw self.appError("Reset Zoom data: refusing to delete files because the home directory '\(home)' is not a safe absolute path.")
                    }
                    let output = try await self.runProcess(
                        stepName: "Reset Zoom data",
                        executable: Constants.bashPath,
                        arguments: ["-c", ShellCommands.makeResetZoomDataWithStatusCommand(homeDirectory: home)]
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
                    finishStep(.init(
                        id: "resetData",
                        name: "Clear Local State",
                        outcome: resetSucceeded ? .success : .warning,
                        detail: resetSucceeded
                            ? (detail.isEmpty ? "Cleared local Zoom caches, preferences, and containers." : detail)
                            : "Could not clear all Zoom data. \(detail)"
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepWarning("resetData")
                    finishStep(.init(id: "resetData", name: "Clear Local State", outcome: .warning, detail: error.localizedDescription))
                    self.appendLog("Warning: \(error.localizedDescription)")
                }

                // 6. DNS flush.
                self.workflowState = .flushingDNS
                beginStep("dns")
                self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
                do {
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
                    finishStep(.init(
                        id: "dns",
                        name: "DNS Flush",
                        outcome: dnsSucceeded ? .success : .warning,
                        detail: dnsSucceeded
                            ? (detail.isEmpty ? "Flushed system DNS cache and restarted mDNSResponder." : detail)
                            : "Could not refresh DNS cache. \(detail)"
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepWarning("dns")
                    finishStep(.init(id: "dns", name: "DNS Flush", outcome: .warning, detail: error.localizedDescription))
                    self.appendLog("Warning: \(error.localizedDescription)")
                }

                // 7. Stop updaters
                self.workflowState = .stoppingUpdaters
                beginStep("updaters")
                self.appendLog("Step: Stop Zoom updaters")
                do {
                    let output = try await self.runProcess(
                        stepName: "Stop Zoom updaters",
                        executable: Constants.bashPath,
                        arguments: ["-c", self.stopZoomUpdatersCommand]
                    )
                    self.markStepDone("updaters", succeeded: true)
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishStep(.init(
                        id: "updaters",
                        name: "Stop Updaters",
                        outcome: .success,
                        detail: trimmed.isEmpty ? "Unloaded Zoom updater agents for the current session." : trimmed
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepWarning("updaters")
                    finishStep(.init(id: "updaters", name: "Stop Updaters", outcome: .warning, detail: error.localizedDescription))
                    self.appendLog("Warning: \(error.localizedDescription)")
                }

                // 8. Ensure camera and microphone access before the sandboxed launch.
                self.workflowState = .checkingMediaAccess
                beginStep("mediaAccess")
                self.appendLog("Step: Check camera and microphone access")
                do {
                    let detail = try await self.ensureMediaAccessForSandboxedZoom()
                    self.markStepDone("mediaAccess", succeeded: true)
                    finishStep(.init(id: "mediaAccess", name: "Camera & Mic", outcome: .success, detail: detail))
                } catch {
                    try Task.checkCancellation()
                    self.markStepWarning("mediaAccess")
                    finishStep(.init(id: "mediaAccess", name: "Camera & Mic", outcome: .warning, detail: error.localizedDescription))
                    self.appendLog("Warning: \(error.localizedDescription)")
                }

                // 9. Launch Zoom
                self.workflowState = .launchingZoom
                beginStep("launch")
                self.appendLog("Step: Launch Zoom")
                do {
                    let verifiedBinaryPath = try await self.verifiedZoomBinaryPath()
                    let output = try await self.runProcess(
                        stepName: "Launch Zoom",
                        executable: Constants.bashPath,
                        arguments: ["-c", ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: verifiedBinaryPath)],
                        timeout: 120
                    )
                    self.markStepDone("launch", succeeded: true)
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishStep(.init(
                        id: "launch",
                        name: "Launch Zoom",
                        outcome: .success,
                        detail: trimmed.isEmpty ? "Launched verified Zoom binary inside sandbox-exec." : trimmed
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepDone("launch", succeeded: false)
                    finishStep(.init(id: "launch", name: "Launch Zoom", outcome: .failed, detail: error.localizedDescription))
                    throw error
                }

                let hasIssues = completedResults.contains { $0.outcome != .success }
                syncRunRecord(outcome: hasIssues ? .completedWithWarnings : .succeeded)
                return WorkflowResultFormatter.summary(for: self.lastRunResults ?? completedResults)
            } catch is CancellationError {
                if let active = activeStepSpec {
                    self.markStepInterrupted(active.id)
                    completedResults.removeAll(where: { $0.id == active.id })
                    completedResults.append(.init(
                        id: active.id,
                        name: active.name,
                        outcome: .interrupted,
                        detail: "Stopped by user."
                    ))
                    self.expandedStepIDs.insert(active.id)
                    activeStepSpec = nil
                }
                syncRunRecord(outcome: .cancelled)
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    if let active = activeStepSpec {
                        self.markStepInterrupted(active.id)
                        completedResults.removeAll(where: { $0.id == active.id })
                        completedResults.append(.init(
                            id: active.id,
                            name: active.name,
                            outcome: .interrupted,
                            detail: "Stopped by user."
                        ))
                        self.expandedStepIDs.insert(active.id)
                        activeStepSpec = nil
                    }
                    syncRunRecord(outcome: .cancelled)
                    throw CancellationError()
                }
                let failedID = completedResults.last(where: { $0.outcome == .failed })?.id ?? activeStepSpec?.id
                syncRunRecord(
                    outcome: .failed,
                    failureMessage: error.localizedDescription,
                    failedStepID: failedID
                )
                throw error
            }
        }
    }

    private func initProgress(steps: [(id: String, name: String)]) {
        workflowProgress = WorkflowProgress(
            steps: steps.map { .init(id: $0.id, name: $0.name, state: .unstarted) },
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

    private func markStepInterrupted(_ id: String) {
        guard var progress = workflowProgress,
              let idx = progress.steps.firstIndex(where: { $0.id == id }) else { return }
        progress.steps[idx].state = .interrupted
        workflowProgress = progress
    }

    private func finalizeProgressOnTermination(wasCancelled: Bool) {
        guard var progress = workflowProgress else { return }
        for index in progress.steps.indices {
            switch progress.steps[index].state {
            case .running:
                progress.steps[index].state = wasCancelled ? .interrupted : .failed
            case .unstarted, .succeeded, .warning, .failed, .skipped, .interrupted:
                break
            }
        }
        workflowProgress = progress
    }

    func cancelWorkflow() {
        guard isRunning, !isCanceling else { return }
        isCanceling = true
        workflowState = .canceling
        if var record = currentRunRecord {
            record.outcome = .stopping
            currentRunRecord = record
        }
        if isExecutingPrivilegedStep {
            appendLog("Stop requested. Waiting for the current privileged administrator step to finish safely…")
        } else {
            appendLog("Stop requested. Finishing the current step safely…")
        }
        runningTask?.cancel()
    }

    func dryRun() {
        guard !isRunning, !runGate.isActive else {
            appendLog("Another task is already running.")
            return
        }
        lastRunResults = nil
        workflowProgress = nil
        runTask("Dry Run") {
            var results: [String] = []

            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            results.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

            let arch = ShellCommands.machineArchitecture()
            results.append("Architecture: \(arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch))")

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
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand()],
                    timeout: 15
                )
                results.append("Sandbox profile: Valid")
            } catch {
                try Task.checkCancellation()
                results.append("Sandbox profile: FAILED — \(error.localizedDescription)")
            }

            if let availableBytes = self.effectiveAvailableBackupBytes() {
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
        logEntries.removeAll()
        logRevision &+= 1
    }

    private func effectiveAvailableBackupBytes() -> Int64? {
        if let override = availableBackupCapacityBytesOverride {
            return override()
        }
        return BackupStore.availableCapacityBytes()
    }

    func runPreflight() {
        preflightTask?.cancel()
        let preflightID = UUID()
        activePreflightID = preflightID
        preflight = PreflightInfo(status: .loading, checks: [])
        let selectedZoomPath = zoomAppPath
        let selectedZoomIsCustom = customZoomAppPath != nil
        let verifier = bundleVerifierOverride

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

            // Verify the selected Zoom bundle without touching it.
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    if let verifier {
                        return try verifier(selectedZoomPath)
                    }
                    return try ZoomBundleVerifier.verify(appPath: selectedZoomPath)
                }.value
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

            // Compile the same sandbox profile used at launch.
            do {
                _ = try await self.runProcess(
                    stepName: "Preflight: validate sandbox",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand()],
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
            if let availableBytes = self.effectiveAvailableBackupBytes() {
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

            checks.append(.init(id: "admin", label: "Admin Prompts", value: "Expected", isWarning: false))

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

    func saveReportDraftAttachment(_ draft: ReportDraft) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = draft.diagnosticsFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try draft.attachmentData.write(to: url, options: .atomic)
            appendLog("Report attachment saved to \(url.lastPathComponent)")
        } catch {
            appendLog("Failed to save report attachment: \(error.localizedDescription)")
        }
    }

    func makeReportDraft(appVersion: String) async -> ReportDraft {
        let now = Date()
        let title = "Bug Report \(Self.bugTitleFormatter.string(from: now))"
        let timestamp = Self.logTimestampFormatter.string(from: now)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let architecture = ShellCommands.machineArchitecture()
        let lastStatus = inferLastActionStatus()
        let selectedPath = DiagnosticsCollector.redactingHomeDirectory(zoomAppPath)
        let readinessText = "\(readinessSnapshot.state.badgeLabel) — \(DiagnosticsCollector.redactingHomeDirectory(readinessSnapshot.headline))"
        let runSummaryText: String
        if let record = currentRunRecord {
            let stepSummary = record.steps
                .filter { $0.outcome != .unstarted }
                .map { "\($0.name): \($0.outcome.displayLabel)" }
                .joined(separator: ", ")
            runSummaryText = "\(record.outcome.badgeLabel)\(stepSummary.isEmpty ? "" : " (\(stepSummary))")"
        } else {
            runSummaryText = "No repair run in this session"
        }

        let systemInfo = """
App version: \(appVersion)
OS: \(osVersion)
Architecture: \(architecture)
Timestamp: \(timestamp)
Selected Zoom path: \(selectedPath)
Readiness: \(readinessText)
Last action status: \(lastStatus)
"""
        let diagnostics = await makeDiagnosticsExport(
            appVersion: appVersion,
            maxLogLines: Self.maxInMemoryLogEntries
        )
        let truncated = ReportDraft.truncateDiagnosticsUTF8(
            diagnostics.content,
            maxBytes: ReportDraft.maxAttachmentBytes
        )
        return ReportDraft(
            id: UUID(),
            createdAt: now,
            title: title,
            appVersion: appVersion,
            selectedAppPath: selectedPath,
            systemInfo: systemInfo,
            readinessSummary: readinessText,
            runSummary: runSummaryText,
            diagnosticsFileName: diagnostics.fileName,
            fullDiagnosticsContent: diagnostics.content,
            attachmentContent: truncated.text,
            attachmentData: truncated.data,
            originalByteCount: truncated.originalBytes,
            wasTruncated: truncated.wasTruncated
        )
    }

    func makeBugReportDraft(appVersion: String) async -> BugReportDraft {
        let reportDraft = await makeReportDraft(appVersion: appVersion)
        return BugReportDraft(
            title: reportDraft.title,
            systemInfo: reportDraft.systemInfo,
            diagnosticsFileName: reportDraft.diagnosticsFileName,
            diagnosticsData: reportDraft.attachmentData
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
        let environmentSnapshot = await Task.detached(priority: .utility) {
            DiagnosticsCollector.makeSnapshot()
        }.value

        var lines: [String] = []
        lines.append("1132 Fixer Diagnostics Report")
        lines.append("Generated: \(timestamp)")
        lines.append("App version: \(appVersion)")
        lines.append("OS: \(osVersion)")
        lines.append("Architecture: \(arch)")
        lines.append("Selected Zoom bundle: \(zoomAppPath)")
        lines.append("Readiness state: \(readinessSnapshot.state.badgeLabel)")
        lines.append("Last action status: \(lastStatus)")
        if let runBackup = currentRunBackupPath {
            lines.append("Current run backup: \(runBackup)")
        } else if let prevBackup = previousBackupPath {
            lines.append("Previous backup on disk: \(prevBackup)")
        }
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
        appendLog("=== \(title) ===")

        runningTask = Task {
            defer {
                if runGate.finish(runID) {
                    isRunning = false
                    isCanceling = false
                    isExecutingPrivilegedStep = false
                    runningTask = nil
                    if processExecutorOverride == nil && bundleVerifierOverride == nil {
                        runPreflight()
                    }
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
                finalizeProgressOnTermination(wasCancelled: true)
                appendLog("=== Canceled safely ===")
            } catch {
                if Task.isCancelled {
                    workflowState = .canceled
                    finalizeProgressOnTermination(wasCancelled: true)
                    appendLog("=== Canceled safely ===")
                    return
                }
                workflowState = .failed(error.localizedDescription)
                finalizeProgressOnTermination(wasCancelled: false)
                appendLog("Error: \(error.localizedDescription)")
                appendLog("=== Failed ===")
            }
        }
    }

    private func appendLog(_ text: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logRevision &+= 1
        let entry = LogEntry(
            sequence: logRevision,
            timestamp: timestamp,
            message: text
        )
        if logs.count >= Self.maxInMemoryLogEntries {
            logs.removeFirst(logs.count - Self.maxInMemoryLogEntries + 1)
        }
        if logEntries.count >= Self.maxInMemoryLogEntries {
            logEntries.removeFirst(logEntries.count - Self.maxInMemoryLogEntries + 1)
        }
        logs.append(entry.formattedLine)
        logEntries.append(entry)
    }

    private func inferLastActionStatus() -> String {
        if let record = currentRunRecord {
            switch record.outcome {
            case .running: return "In Progress"
            case .stopping: return "Stopping"
            case .succeeded: return "Completed"
            case .completedWithWarnings: return "Completed with Warnings"
            case .failed: return "Error"
            case .cancelled: return "Canceled"
            }
        }
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
        try Task.checkCancellation()
        let macVerified = !actualMAC.isEmpty && actualMAC == spoofedMAC.lowercased()

        var warnings: [String] = []
        let summary: String
        if macVerified {
            summary = "MAC spoofed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.isEmpty
                ? "Could not read the current MAC address after spoofing."
                : "Current MAC (\(actualMAC)) does not match target (\(spoofedMAC))."
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
        let previousMAC = (try? await runProcess(
            stepName: "Read current MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        try Task.checkCancellation()

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
        }

        let newMAC = (try? await runProcess(
            stepName: "Read new MAC address",
            executable: Constants.bashPath,
            arguments: ["-c", verifyScript]
        ))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
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
        if newMAC.isEmpty {
            warnings.append("Warning: The current MAC address could not be read after cycling Wi-Fi.")
        } else if !previousMAC.isEmpty && newMAC == previousMAC {
            warnings.append("Warning: Wi-Fi reconnected, but the MAC address did not change (\(newMAC)).")
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

        let displayedMAC = newMAC.isEmpty ? "(could not read)" : newMAC
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
            let routeOutput = try await runProcess(
                stepName: "Verify network recovery",
                executable: Constants.bashPath,
                arguments: ["-c", "/sbin/route -n get default 2>/dev/null"],
                timeout: 15
            )
            let recoveredDevice = try ShellCommands.parseDefaultRouteInterface(from: routeOutput)
            guard recoveredDevice == expectedDevice else {
                return "Warning: The default route moved from \(expectedDevice) to \(recoveredDevice) after the network change."
            }
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

    private func verifiedZoomBinaryPath() async throws -> String {
        let appPath = zoomAppPath
        let verifier = bundleVerifierOverride
        let verified = try await Task.detached(priority: .userInitiated) {
            if let verifier {
                return try verifier(appPath)
            }
            return try ZoomBundleVerifier.verify(appPath: appPath)
        }.value
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
        selectZoomLocation(at: url.path)
    }

    func selectZoomLocation(at selectedPath: String) {
        guard let validated = ZoomLocation.validatedAppPath(selectedPath) else {
            let reason = "The selected app does not contain the Zoom executable. Choose 'zoom.us.app'."
            appendLog("Selected app is not a valid Zoom installation: \(selectedPath)")
            installationNotice = reason
            workflowState = .failed(reason)
            return
        }

        do {
            if let verifier = bundleVerifierOverride {
                _ = try verifier(validated)
            } else {
                _ = try ZoomBundleVerifier.verify(appPath: validated)
            }
        } catch {
            appendLog("Selected app was rejected: \(error.localizedDescription)")
            installationNotice = error.localizedDescription
            workflowState = .failed(error.localizedDescription)
            return
        }

        installationNotice = nil
        ZoomLocation.customAppPath = validated
        customZoomAppPath = validated
        appendLog("Zoom location set to: \(validated)")
        runPreflight()
    }

    /// Reverts to the default `/Applications/zoom.us.app` location.
    func resetZoomLocation() {
        installationNotice = nil
        ZoomLocation.customAppPath = nil
        customZoomAppPath = nil
        appendLog("Zoom location reset to default: \(ZoomLocation.defaultAppPath)")
        runPreflight()
    }

    func revealBackup(at path: String?) {
        let candidate = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BackupStore.latestBackupURL()
        guard let candidate, BackupStore.isManagedBackupURL(candidate) else {
            appendLog("No managed Zoom backup is available to reveal.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }

    func revealLatestBackup() {
        let candidatePath = currentRunBackupPath ?? previousBackupPath ?? latestBackupPath
        let candidate = candidatePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? BackupStore.latestBackupURL()
        guard let candidate, BackupStore.isManagedBackupURL(candidate) else {
            currentRunBackupPath = nil
            previousBackupPath = nil
            latestBackupPath = nil
            appendLog("No managed Zoom backup is available to reveal.")
            return
        }

        latestBackupPath = candidate.path
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }

    // MARK: - Media Access

    private static let mediaAccessPromptTimeout: TimeInterval = 60

    private struct MediaAccessResult {
        let isGranted: Bool
        let message: String
    }

    private func ensureMediaAccessForSandboxedZoom() async throws -> String {
        if processExecutorOverride != nil {
            return "Camera access already granted; Microphone access already granted"
        }

        if !skipBringAppToFront {
            await bringAppToFront()
        }

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

    private func requestMediaAccess(for mediaType: AVMediaType) async -> MediaAccessOutcome {
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

    private func bringAppToFront() async {
        let app = NSApplication.shared
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
        app.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
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

    nonisolated private static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier

        let childKiller = Process()
        childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        childKiller.arguments = ["-TERM", "-P", "\(pid)"]
        childKiller.standardOutput = FileHandle.nullDevice
        childKiller.standardError = FileHandle.nullDevice
        if (try? childKiller.run()) != nil {
            childKiller.waitUntilExit()
        }

        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Runs a process and returns its combined output.
    private func runProcess(
        stepName: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) async throws -> String {
        try Task.checkCancellation()

        let isPrivileged = (executable == Constants.osascriptPath)
        if isPrivileged {
            isExecutingPrivilegedStep = true
        }
        defer {
            if isPrivileged {
                isExecutingPrivilegedStep = false
            }
        }

        if let override = processExecutorOverride {
            return try await override(stepName, executable, arguments, timeout)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let cancellationFlag = LockedFlag()
        let timeoutFlag = LockedFlag()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let stdoutBuffer = LockedDataBuffer()
                let stderrBuffer = LockedDataBuffer()
                let resumeGate = ContinuationResumeGate()
                let readGroup = DispatchGroup()

                @Sendable func safeResume(_ result: Result<String, Error>) {
                    guard resumeGate.beginResume() else { return }
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    timeoutFlag.set()
                    AppViewModel.terminateProcessTree(process)
                    DispatchQueue.main.async {
                        self.appendLog("Timeout: '\(stepName)' did not complete within \(Int(timeout))s — terminating.")
                    }
                }
                timer.resume()

                process.terminationHandler = { terminatedProcess in
                    let terminationStatus = terminatedProcess.terminationStatus

                    readGroup.notify(queue: .global()) {
                        timer.cancel()

                        let stdout = String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
                        let stderr = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""
                        let combined = [stdout, stderr]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")

                        if cancellationFlag.isSet {
                            safeResume(.failure(CancellationError()))
                            return
                        }

                        if timeoutFlag.isSet {
                            safeResume(.failure(AppError.processTimeout("\(stepName): Timed out after \(Int(timeout)) seconds.")))
                            return
                        }

                        if terminationStatus == 0 {
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
                            message = "\(stepName): Command failed with exit code \(terminationStatus)."
                        }

                        safeResume(.failure(AppError.processFailed(
                            exitCode: Int(terminationStatus),
                            message: message
                        )))
                    }
                }

                readGroup.enter()
                readGroup.enter()

                if cancellationFlag.isSet {
                    readGroup.leave()
                    readGroup.leave()
                    timer.cancel()
                    safeResume(.failure(CancellationError()))
                    return
                }

                do {
                    try process.run()
                } catch {
                    readGroup.leave()
                    readGroup.leave()
                    timer.cancel()
                    safeResume(.failure(error))
                    return
                }

                for (pipe, buffer) in [(outPipe, stdoutBuffer), (errPipe, stderrBuffer)] {
                    DispatchQueue.global().async {
                        if let data = try? pipe.fileHandleForReading.readToEnd() {
                            buffer.append(data)
                        }
                        readGroup.leave()
                    }
                }
            }
        }, onCancel: {
            cancellationFlag.set()
            // Privileged AppleScript shells cannot be killed safely from this process.
            // Let their bounded watchdog finish, keeping the run locked until they exit.
            if executable != Constants.osascriptPath {
                AppViewModel.terminateProcessTree(process)
            }
        })
    }

    // MARK: - Deterministic UI Fixture Support (Validation & Screenshots)

    func applyUIFixtureIfRequested(appVersion: String) {
        guard let fixtureName = ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"],
              !fixtureName.isEmpty else {
            return
        }
        applyUIFixture(named: fixtureName, appVersion: appVersion)
    }

    func applyUIFixture(named fixtureName: String, appVersion: String = "1.8.2") {
        preflightTask?.cancel()
        activePreflightID = UUID()

        let readyChecks: [PreflightInfo.Check] = [
            .init(id: "os", label: "macOS", value: "macOS 15.1.0", isWarning: false),
            .init(id: "arch", label: "Architecture", value: "Apple Silicon", isWarning: false),
            .init(id: "zoom", label: "Zoom App", value: "Verified", isWarning: false),
            .init(id: "sandbox", label: "Sandbox", value: "Profile validated", isWarning: false),
            .init(id: "storage", label: "Backup Space", value: "148.4 GB available", isWarning: false),
            .init(id: "iface", label: "Active Interface", value: "Wi-Fi (en0)", isWarning: false),
            .init(id: "vpn", label: "VPN", value: "No VPN default route detected", isWarning: false),
            .init(id: "admin", label: "Admin Prompts", value: "Expected", isWarning: false),
            .init(id: "macspoof", label: "Network Identity", value: "Rotating Private Wi-Fi Address", isWarning: false),
            .init(id: "camera", label: "Camera", value: "Allowed", isWarning: false),
            .init(id: "microphone", label: "Microphone", value: "Allowed", isWarning: false),
        ]

        let canonical = RepairStepSpec.canonicalSteps()
        appendLog("Loaded validation fixture: \(fixtureName)")

        switch fixtureName {
        case "ready":
            preflight = PreflightInfo(status: .ready, checks: readyChecks)

        case "warning":
            var checks = readyChecks
            checks[6] = .init(id: "vpn", label: "VPN", value: "Active (turn off before running)", isWarning: true)
            checks[9] = .init(id: "camera", label: "Camera", value: "Will request access when needed", isWarning: true)
            preflight = PreflightInfo(status: .ready, checks: checks)

        case "blocked":
            var checks = readyChecks
            checks[2] = .init(
                id: "zoom",
                label: "Zoom App",
                value: "Zoom is not installed at /Applications/zoom.us.app. Choose a valid Zoom.app bundle.",
                isWarning: true,
                isBlocking: true
            )
            preflight = PreflightInfo(status: .ready, checks: checks)

        case "review":
            preflight = PreflightInfo(status: .ready, checks: readyChecks)
            prepareAndPresentRepairPlan()

        case "running", "stopping":
            preflight = PreflightInfo(status: .ready, checks: readyChecks)
            isRunning = true
            isCanceling = (fixtureName == "stopping")
            isExecutingPrivilegedStep = (fixtureName == "stopping")
            workflowState = (fixtureName == "stopping") ? .canceling : .flushingDNS
            let backupDir = "/Users/user/Library/Application Support/1132Fixer/Backups/zoom.us-backup-20261019-040000"
            currentRunBackupPath = backupDir
            latestBackupPath = backupDir
            let steps: [StepResult] = canonical.map { spec in
                switch spec.index {
                case 1...5:
                    return StepResult(id: spec.id, name: spec.name, outcome: .success, detail: "Completed cleanly.")
                case 6:
                    return StepResult(
                        id: spec.id,
                        name: spec.name,
                        outcome: .running,
                        detail: fixtureName == "stopping"
                            ? "Waiting for privileged DNS flush subprocess to exit safely…"
                            : "Refreshing system DNS cache with administrator privileges…"
                    )
                default:
                    return StepResult(id: spec.id, name: spec.name, outcome: .unstarted, detail: "Not run")
                }
            }
            lastRunResults = steps
            currentRunRecord = RunRecord(
                id: UUID(),
                title: "Repair Zoom 1132",
                startedAt: Date().addingTimeInterval(-14),
                finishedAt: nil,
                selectedAppPath: zoomAppPath,
                outcome: fixtureName == "stopping" ? .stopping : .running,
                steps: steps,
                createdBackupPath: backupDir,
                failureMessage: nil,
                failedStepID: nil
            )

        case "failed_after_backup":
            preflight = PreflightInfo(status: .ready, checks: readyChecks)
            isRunning = false
            isCanceling = false
            let failureMsg = "Launch Zoom: sandbox-exec exited with code 71 ( Zoom binary failed to initialize )."
            workflowState = .failed(failureMsg)
            let backupDir = "/Users/user/Library/Application Support/1132Fixer/Backups/zoom.us-backup-20261019-040500"
            currentRunBackupPath = backupDir
            latestBackupPath = backupDir
            let steps: [StepResult] = canonical.map { spec in
                switch spec.index {
                case 1, 2, 5, 6, 7, 8:
                    return StepResult(id: spec.id, name: spec.name, outcome: .success, detail: "Completed cleanly.")
                case 3:
                    return StepResult(id: spec.id, name: spec.name, outcome: .success, detail: "Saved to \(backupDir)")
                case 4:
                    return StepResult(id: spec.id, name: spec.name, outcome: .warning, detail: "Private Wi-Fi Address cycled; MAC rotation warning noted.")
                default:
                    return StepResult(id: spec.id, name: spec.name, outcome: .failed, detail: failureMsg)
                }
            }
            lastRunResults = steps
            expandedStepIDs = ["network", "launch"]
            currentRunRecord = RunRecord(
                id: UUID(),
                title: "Repair Zoom 1132",
                startedAt: Date().addingTimeInterval(-28),
                finishedAt: Date(),
                selectedAppPath: zoomAppPath,
                outcome: .failed,
                steps: steps,
                createdBackupPath: backupDir,
                failureMessage: failureMsg,
                failedStepID: "launch"
            )

        case "bug_report":
            preflight = PreflightInfo(status: .ready, checks: readyChecks)
            appendLog("Step: Verify Zoom signature and required sandbox profile")
            appendLog("Step: Backup Zoom local state")
            appendLog("Error: Sample diagnostic log entry for bug report attachment inspection.")
            let sampleDiag = """
1132 Fixer Diagnostics Report
Generated: 2026-10-19T08:00:00Z
App version: \(appVersion)
OS: macOS 15.1.0
Architecture: arm64
Selected Zoom bundle: /Applications/zoom.us.app
Readiness state: Ready
Last action status: Error

--- Step Results ---
[OK] Safety Check — Verified signature and compiled sandbox launch profile.
[OK] Close Zoom — Zoom processes closed cleanly.
[OK] Backup State — Saved to ~/Library/Application Support/1132Fixer/Backups/zoom.us-backup-20261019-040500
[FAIL] Launch Zoom — sandbox-exec exited with code 71.

--- Activity Log (3 entries) ---
[2026-10-19T08:00:00Z] Step: Verify Zoom signature and required sandbox profile
[2026-10-19T08:00:01Z] Step: Backup Zoom local state
[2026-10-19T08:00:02Z] Error: Sample diagnostic log entry for bug report attachment inspection.
"""
            let truncated = ReportDraft.truncateDiagnosticsUTF8(sampleDiag)
            activeReportDraft = ReportDraft(
                id: UUID(),
                createdAt: Date(),
                title: "Bug Report 2026-10-19 04:05:00 -0400",
                appVersion: appVersion,
                selectedAppPath: "/Applications/zoom.us.app",
                systemInfo: "App version: \(appVersion)\nOS: macOS 15.1.0\nArchitecture: arm64\nReadiness: Ready",
                readinessSummary: "Ready — Ready to repair Zoom error 1132",
                runSummary: "Failed (Safety Check: Succeeded, Close Zoom: Succeeded, Backup State: Succeeded, Launch Zoom: Failed)",
                diagnosticsFileName: Self.diagnosticsFileName,
                fullDiagnosticsContent: sampleDiag,
                attachmentContent: truncated.text,
                attachmentData: truncated.data,
                originalByteCount: truncated.originalBytes,
                wasTruncated: truncated.wasTruncated
            )

        default:
            preflight = PreflightInfo(status: .ready, checks: readyChecks)
        }
    }
}

/// The result of a single `AVCaptureDevice.requestAccess` call.
enum MediaAccessOutcome: Equatable {
    case answered(Bool)
    case unanswered
}

final class MediaAccessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaAccessOutcome, Never>?
    private var outcome: MediaAccessOutcome?

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
