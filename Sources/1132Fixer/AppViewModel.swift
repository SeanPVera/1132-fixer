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
    static let maxInMemoryLogEntries = 2_000
    static let maxInMemoryLogBytes = 512 * 1_024
    static let maxSingleLogEntryBytes = 32 * 1_024

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
    var requireOnDiskBackupVerification = false

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

    init(
        initialDiskBackupPath: String? = BackupStore.latestBackupURL()?.path,
        processExecutor: any ProcessExecuting = BoundedProcessExecutor(),
        zoomVerifier: @escaping ZoomVerifier = { try await ZoomBundleVerifier.verify(appPath: $0) },
        mediaAccessChecker: MediaAccessChecker? = nil,
        homeDirectoryProvider: @escaping () -> String = NSHomeDirectory
    ) {
        self.processExecutor = processExecutor
        self.zoomVerifier = zoomVerifier
        self.mediaAccessChecker = mediaAccessChecker
        self.homeDirectoryProvider = homeDirectoryProvider

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
              !(AppConfiguration.allowsDebugEnvironmentOverrides && ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"] != nil) else {
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

        let requestedHomeDirectory = homeDirectoryProvider()
        let normalizedHomeDirectory = ShellCommands.normalizedSafeHomeDirectory(requestedHomeDirectory)
        let homeDirectory = normalizedHomeDirectory.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path
        } ?? requestedHomeDirectory

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
                        arguments: ["-c", ShellCommands.makeBackupZoomDataCommand(homeDirectory: homeDirectory)],
                        timeout: 60
                    )
                    let backupPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !backupPath.isEmpty else {
                        throw self.appError("Backup completed without returning a recovery location.")
                    }
                    if self.requireOnDiskBackupVerification || (self.processExecutorOverride == nil && self.processExecutor is BoundedProcessExecutor) {
                        let backupURL = URL(fileURLWithPath: backupPath, isDirectory: true)
                        let expectedRootURL = BackupStore.rootURL(forHomeDirectory: homeDirectory)
                        guard BackupStore.isManagedBackupURL(backupURL, rootURL: expectedRootURL) else {
                            throw self.appError("Backup verification failed: '\(backupPath)' is not a valid recovery snapshot on disk.")
                        }
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
                    guard ShellCommands.isSafeHomeDirectory(homeDirectory) else {
                        throw self.appError("Reset Zoom data: refusing to delete files because the home directory '\(homeDirectory)' is not a safe absolute path.")
                    }
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
                        arguments: ["-c", ShellCommands.makeLaunchZoomCommand(
                            zoomBinaryPath: verifiedBinaryPath,
                            homeDirectory: homeDirectory
                        )],
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
        expandedStepIDs.removeAll()
        let canonicalSpecs = RepairStepSpec.canonicalSteps()
        initProgress(steps: canonicalSpecs.map { ($0.id, $0.name) })
        let runRecordID = UUID()
        let selectedPath = zoomAppPath
        currentRunRecord = RunRecord(
            id: runRecordID,
            title: "Preview Steps (Dry Run)",
            startedAt: Date(),
            finishedAt: nil,
            selectedAppPath: selectedPath,
            outcome: .running,
            steps: canonicalSpecs.map { StepResult(id: $0.id, name: $0.name, outcome: .unstarted, detail: "Pending") },
            createdBackupPath: nil,
            failureMessage: nil,
            failedStepID: nil
        )
        runTask("Dry Run") {
            var results: [String] = []
            var completedResults: [StepResult] = []
            var activeStepSpec: RepairStepSpec?

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
                    title: "Preview Steps (Dry Run)",
                    startedAt: self.currentRunRecord?.startedAt ?? Date(),
                    finishedAt: (outcome == .running || outcome == .stopping) ? nil : Date(),
                    selectedAppPath: selectedPath,
                    outcome: outcome,
                    steps: merged,
                    createdBackupPath: nil,
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
            func finishStep(_ id: String, outcome: StepResult.Outcome, detail: String) {
                let name = canonicalSpecs.first(where: { $0.id == id })?.name ?? id
                switch outcome {
                case .success:
                    self.markStepDone(id, succeeded: true)
                case .failed:
                    self.markStepDone(id, succeeded: false)
                case .warning:
                    self.markStepWarning(id)
                case .skipped:
                    self.markStepSkipped(id)
                case .interrupted:
                    self.markStepInterrupted(id)
                case .unstarted, .running:
                    break
                }
                let result = StepResult(id: id, name: name, outcome: outcome, detail: detail)
                completedResults.removeAll(where: { $0.id == id })
                completedResults.append(result)
                if activeStepSpec?.id == id {
                    activeStepSpec = nil
                }
                if outcome == .failed || outcome == .warning {
                    self.expandedStepIDs.insert(id)
                }
                syncRunRecord(outcome: self.isCanceling ? .stopping : .running)
            }

            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            results.append("macOS: \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")

            let arch = ShellCommands.machineArchitecture()
            results.append("Architecture: \(arch == "arm64" ? "Apple Silicon" : (arch == "x86_64" ? "Intel" : arch))")

            self.workflowState = .preflight
            beginStep("validate")
            var validateFailure: String?
            let requestedHome = self.homeDirectoryProvider()
            let normalizedHome = ShellCommands.normalizedSafeHomeDirectory(requestedHome).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path
            }
            var isHomeDir: ObjCBool = false
            let homeIsSafe = normalizedHome.map {
                ShellCommands.isSafeHomeDirectory($0)
                    && FileManager.default.fileExists(atPath: $0, isDirectory: &isHomeDir)
                    && isHomeDir.boolValue
            } ?? false
            if !homeIsSafe {
                validateFailure = "Safety checks: home directory '\(requestedHome)' is not a safe, existing directory."
            }

            do {
                let verified = try await self.verifiedZoomBinaryPath()
                results.append("Zoom signature: Verified")
                results.append("Zoom binary: \(verified)")
            } catch {
                try Task.checkCancellation()
                results.append("Zoom signature: FAILED — \(error.localizedDescription)")
                if validateFailure == nil {
                    validateFailure = error.localizedDescription
                }
            }

            do {
                let sandboxHome = normalizedHome ?? requestedHome
                _ = try await self.runProcess(
                    stepName: "Validate Zoom sandbox profile",
                    executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand(
                        homeDirectory: sandboxHome
                    )],
                    timeout: 15
                )
                results.append("Sandbox profile: Valid")
            } catch {
                try Task.checkCancellation()
                results.append("Sandbox profile: FAILED — \(error.localizedDescription)")
                if validateFailure == nil {
                    validateFailure = error.localizedDescription
                }
            }

            if let validateFailure {
                finishStep("validate", outcome: .failed, detail: validateFailure)
            } else {
                finishStep(
                    "validate",
                    outcome: .success,
                    detail: "Verified Zoom bundle and sandbox launch profile (read-only preview)."
                )
            }

            self.workflowState = .closingZoom
            beginStep("closeZoom")
            let zoomRunning = (try? await self.runProcess(
                stepName: "Check Zoom process",
                executable: Constants.bashPath,
                arguments: ["-c", "/usr/bin/pgrep -x \"zoom.us\" >/dev/null 2>&1 && echo running || echo stopped"]
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            results.append("Zoom process: \(zoomRunning)")
            finishStep(
                "closeZoom",
                outcome: .skipped,
                detail: "Read-only preview: Zoom process is \(zoomRunning); live repair would close Zoom before backup."
            )

            self.workflowState = .backingUpState
            beginStep("backup")
            let spaceDetail: String
            if let availableBytes = self.effectiveAvailableBackupBytes() {
                let formatted = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
                results.append("Backup space available: \(formatted)")
                spaceDetail = "Backup space available: \(formatted)"
            } else {
                results.append("Backup space available: Could not determine")
                spaceDetail = "Backup space available: Could not determine"
            }
            finishStep(
                "backup",
                outcome: .skipped,
                detail: "Read-only preview: \(spaceDetail); live repair would create a private backup before any reset."
            )

            self.workflowState = .checkingNetwork
            beginStep("network")
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

                var networkOutcome: StepResult.Outcome = .skipped
                var strategyDetail = "Active interface: \(portName) (\(device))"
                if let kind = try? ShellCommands.classifySupportedInterface(hardwarePortName: portName) {
                    results.append("Interface type: \(kind.rawValue)")
                    switch ShellCommands.networkIdentityStrategy(isWiFi: kind == .wifi) {
                    case .rotatingPrivateWiFiAddress:
                        let desc = "Rotating Private Wi-Fi Address (Apple Silicon + macOS 14+)"
                        results.append("Network identity: \(desc)")
                        strategyDetail += " — Read-only preview: would use \(desc)."
                    case .unsupported:
                        let desc = "UNAVAILABLE — MAC spoofing is disabled on macOS 14+"
                        results.append("Network identity: \(desc)")
                        strategyDetail += " — \(desc)."
                        networkOutcome = .warning
                    case .legacyMACSpoof:
                        let desc = "MAC spoofing available"
                        results.append("Network identity: \(desc)")
                        strategyDetail += " — Read-only preview: \(desc)."
                    }
                }
                finishStep("network", outcome: networkOutcome, detail: strategyDetail)
            } catch {
                try Task.checkCancellation()
                results.append("Network: \(error.localizedDescription)")
                finishStep(
                    "network",
                    outcome: .warning,
                    detail: "Read-only preview: \(error.localizedDescription)"
                )
            }

            self.workflowState = .clearingState
            beginStep("resetData")
            finishStep(
                "resetData",
                outcome: .skipped,
                detail: "Read-only preview: would clear local Zoom state, saved window state, and logs."
            )

            self.workflowState = .flushingDNS
            beginStep("dns")
            finishStep(
                "dns",
                outcome: .skipped,
                detail: "Read-only preview: would flush system DNS cache (administrator prompt in live repair)."
            )

            self.workflowState = .stoppingUpdaters
            beginStep("updaters")
            finishStep(
                "updaters",
                outcome: .skipped,
                detail: "Read-only preview: would unload Zoom LaunchAgents for the current session."
            )

            self.workflowState = .checkingMediaAccess
            beginStep("mediaAccess")
            let camera = Self.mediaAccessPreflightValue(for: .video)
            let microphone = Self.mediaAccessPreflightValue(for: .audio)
            results.append("Camera access: \(camera.value)")
            results.append("Microphone access: \(microphone.value)")
            let mediaHasWarning = camera.isWarning || microphone.isWarning
            finishStep(
                "mediaAccess",
                outcome: mediaHasWarning ? .warning : .success,
                detail: "Camera access: \(camera.value); Microphone access: \(microphone.value)"
            )

            self.workflowState = .launchingZoom
            beginStep("launch")
            finishStep(
                "launch",
                outcome: .skipped,
                detail: "Read-only preview: would launch verified Zoom binary inside sandbox-exec."
            )

            let hasAdvisories = completedResults.contains { $0.outcome == .warning || $0.outcome == .failed }
            syncRunRecord(outcome: hasAdvisories ? .completedWithWarnings : .succeeded)

            results.append("")
            results.append("Dry run complete. No changes were made to your system.")
            return results.joined(separator: "\n")
        }
    }

    func clearLogs() {
        logs.removeAll()
        logEntries.removeAll()
        retainedLogBytes = 0
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
                if let verifier {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try verifier(selectedZoomPath)
                    }.value
                } else {
                    _ = try await self.zoomVerifier(selectedZoomPath)
                }
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
        let environmentSnapshot = await DiagnosticsCollector.makeSnapshot(executor: processExecutor)

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
        let clock = ContinuousClock()
        let startedAt = clock.now
        appendLog("=== \(title) ===")

        runningTask = Task {
            defer {
                if runGate.finish(runID) {
                    appendLog("Timing: \(title) finished in \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
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
        let boundedText = Self.tailLimitedUTF8(text, maxBytes: Self.maxSingleLogEntryBytes)
        logRevision &+= 1
        let entry = LogEntry(
            sequence: logRevision,
            timestamp: timestamp,
            message: boundedText
        )
        let formatted = entry.formattedLine
        logs.append(formatted)
        logEntries.append(entry)
        retainedLogBytes += formatted.utf8.count

        while logs.count > Self.maxInMemoryLogEntries || retainedLogBytes > Self.maxInMemoryLogBytes {
            guard !logs.isEmpty else { break }
            retainedLogBytes -= logs.removeFirst().utf8.count
            if !logEntries.isEmpty {
                logEntries.removeFirst()
            }
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

    private func verifiedZoomBinaryPath() async throws -> String {
        let appPath = zoomAppPath
        if let verifier = bundleVerifierOverride {
            let verified = try await Task.detached(priority: .userInitiated) {
                try verifier(appPath)
            }.value
            return verified.binaryPath
        }
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
        selectZoomLocation(at: url.path)
    }

    func selectZoomLocation(at selectedPath: String) {
        cancelPendingZoomLocationSelection()
        guard let validated = ZoomLocation.validatedAppPath(selectedPath) else {
            let reason = "The selected app does not contain the Zoom executable. Choose 'zoom.us.app'."
            appendLog("Selected app is not a valid Zoom installation: \(selectedPath)")
            installationNotice = reason
            workflowState = .failed(reason)
            return
        }

        if let verifier = bundleVerifierOverride {
            do {
                _ = try verifier(validated)
                installationNotice = nil
                ZoomLocation.customAppPath = validated
                customZoomAppPath = validated
                appendLog("Zoom location set to: \(validated)")
                runPreflight()
            } catch {
                appendLog("Selected app was rejected: \(error.localizedDescription)")
                installationNotice = error.localizedDescription
                workflowState = .failed(error.localizedDescription)
            }
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
                guard finishZoomLocationSelection(selectionID) else { return }

                installationNotice = nil
                ZoomLocation.customAppPath = validated
                customZoomAppPath = validated
                appendLog("Zoom location set to: \(validated)")
                runPreflight()
            } catch is CancellationError {
                _ = finishZoomLocationSelection(selectionID)
            } catch {
                guard finishZoomLocationSelection(selectionID) else { return }
                appendLog("Selected app was rejected: \(error.localizedDescription)")
                installationNotice = error.localizedDescription
                workflowState = .failed(error.localizedDescription)
            }
        }
    }

    private func cancelPendingZoomLocationSelection() {
        activeZoomLocationSelectionID = nil
        zoomLocationSelectionTask?.cancel()
        zoomLocationSelectionTask = nil
    }

    private func finishZoomLocationSelection(_ selectionID: UUID) -> Bool {
        guard activeZoomLocationSelectionID == selectionID else { return false }
        activeZoomLocationSelectionID = nil
        zoomLocationSelectionTask = nil
        return true
    }

    /// Reverts to the default `/Applications/zoom.us.app` location.
    func resetZoomLocation() {
        cancelPendingZoomLocationSelection()
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
        if let mediaAccessChecker {
            return try await mediaAccessChecker()
        }
        if processExecutorOverride != nil {
            return "Camera access already granted; Microphone access already granted"
        }

        // macOS only presents a privacy prompt while the requesting app is
        // frontmost. The admin (SecurityAgent) prompts in the earlier steps leave
        // another process in front, so without this the prompt is deferred and
        // the step waits on a dialog the user never gets to answer.
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

        let isPrivileged = (executable == Constants.osascriptPath)
        if isPrivileged {
            isExecutingPrivilegedStep = true
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        defer {
            if isPrivileged {
                isExecutingPrivilegedStep = false
            }
            appendLog("Timing: \(stepName) took \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
        }

        if let override = processExecutorOverride {
            return try await override(stepName, executable, arguments, timeout)
        }

        do {
            let result: ProcessExecutionResult
            if isPrivileged {
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

    // MARK: - Deterministic UI Fixture Support (Validation & Screenshots)

    func applyUIFixtureIfRequested(appVersion: String) {
        guard AppConfiguration.allowsDebugEnvironmentOverrides,
              let fixtureName = ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"],
              !fixtureName.isEmpty else {
            return
        }
        applyUIFixture(named: fixtureName, appVersion: appVersion)
    }

    func applyUIFixture(named fixtureName: String, appVersion: String = "1.8.3") {
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
