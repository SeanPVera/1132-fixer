import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppViewModel: ObservableObject {
    typealias ZoomVerifier = (_ appPath: String) async throws -> ZoomBundleVerifier.VerifiedBundle
    typealias MediaAccessChecker = () async throws -> String
    typealias BackupVerifier = (_ snapshotPath: String, _ homeDirectory: String) -> Bool

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

    private struct PrivilegedDNSResult {
        let succeeded: Bool
        let detail: String
    }

    private struct MACSpoofResult {
        let summary: String
        let hasWarning: Bool
        let wasSkipped: Bool
        let dnsResult: PrivilegedDNSResult?

        init(
            summary: String,
            hasWarning: Bool,
            wasSkipped: Bool,
            dnsResult: PrivilegedDNSResult? = nil
        ) {
            self.summary = summary
            self.hasWarning = hasWarning
            self.wasSkipped = wasSkipped
            self.dnsResult = dnsResult
        }
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
        case completedWithWarnings
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
    @Published private(set) var privilegedOperationNeedsSettlement: Bool
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
    private var zoomLocationSelectionTask: Task<Void, Never>?
    private var runGate = WorkflowRunGate()
    private var activePreflightID: UUID?
    private var activeZoomLocationSelectionID: UUID?
    private var retainedLogBytes = 0
    private let processExecutor: any ProcessExecuting
    private let zoomVerifier: ZoomVerifier
    private let mediaAccessChecker: MediaAccessChecker?
    private let backupVerifier: BackupVerifier
    private let refreshPreflightAfterRun: Bool
    private let homeDirectoryProvider: () -> String
    private let networkEnvironment: () -> NetworkEnvironment
    private let privilegedGuard: PrivilegedOperationGuard
    private var lastPrivilegedOutput: String?
    private let stopZoomCommand = ShellCommands.stopZoom
    private let stopZoomUpdatersCommand = ShellCommands.stopZoomUpdaters

    /// The `zoom.us.app` bundle path currently in effect. `nil` means the default
    /// `/Applications` location; a non-nil value is a user-selected location.
    @Published var customZoomAppPath: String? = ZoomLocation.customAppPath

    /// The effective `zoom.us.app` bundle path (default or user-selected).
    var zoomAppPath: String {
        customZoomAppPath ?? ZoomLocation.appPath
    }

    var hasUnsettledPrivilegedOperation: Bool {
        privilegedOperationNeedsSettlement || (!isExecutingPrivilegedStep && privilegedGuard.requiresSettlement)
    }

    var isOperationGateActive: Bool {
        runGate.isActive || hasUnsettledPrivilegedOperation
    }

    var canStartZoom: Bool {
        guard case .ready = preflight.status else { return false }
        return !preflight.checks.contains(where: \.isBlocking) && !isRunning && !isOperationGateActive
    }

    init(
        initialDiskBackupPath: String? = BackupStore.latestBackupURL()?.path,
        processExecutor: any ProcessExecuting = BoundedProcessExecutor(),
        zoomVerifier: @escaping ZoomVerifier = { try await ZoomBundleVerifier.verify(appPath: $0) },
        mediaAccessChecker: MediaAccessChecker? = nil,
        homeDirectoryProvider: @escaping () -> String = NSHomeDirectory,
        privilegedGuard: PrivilegedOperationGuard? = nil,
        networkEnvironment: @escaping () -> NetworkEnvironment = { .current },
        backupVerifier: @escaping BackupVerifier = { path, home in
            BackupStore.isManagedBackupURL(URL(fileURLWithPath: path, isDirectory: true), rootURL: BackupStore.rootURL(forHomeDirectory: home))
        },
        refreshPreflightAfterRun: Bool = true
    ) {
        self.processExecutor = processExecutor
        self.zoomVerifier = zoomVerifier
        self.mediaAccessChecker = mediaAccessChecker
        self.backupVerifier = backupVerifier
        self.refreshPreflightAfterRun = refreshPreflightAfterRun
        self.homeDirectoryProvider = homeDirectoryProvider
        self.networkEnvironment = networkEnvironment
        let operationGuard = privilegedGuard ?? PrivilegedOperationGuard()
        self.privilegedGuard = operationGuard
        self.privilegedOperationNeedsSettlement = operationGuard.requiresSettlement

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
            isCustomLocation: customZoomAppPath != nil,
            macSpoofingDisabled: networkEnvironment().osMajor >= 14
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

    func launchZoomOnly() {
        guard canStartZoom else {
            appendLog(hasUnsettledPrivilegedOperation ? PrivilegedOperationGuard.recoveryMessage : "Sandbox launch requires passing system checks.")
            return
        }
        let specs = RepairStepSpec.canonicalSteps().filter { ["validate", "closeZoom", "mediaAccess", "launch"].contains($0.id) }
        let selectedPath = zoomAppPath
        if let priorBackup = currentRunBackupPath { previousBackupPath = priorBackup }
        currentRunBackupPath = nil
        latestBackupPath = previousBackupPath
        lastRunResults = nil
        expandedStepIDs.removeAll()
        initProgress(steps: specs.map { ($0.id, $0.name) })
        currentRunRecord = RunRecord(id: UUID(), title: "Sandbox-only Zoom launch", startedAt: Date(), finishedAt: nil,
            selectedAppPath: selectedPath, outcome: .running,
            steps: specs.map { .init(id: $0.id, name: $0.name, outcome: .unstarted) },
            createdBackupPath: nil, failureMessage: nil, failedStepID: nil)

        runTask("Sandbox-only Zoom launch") {
            var activeID = "validate"
            @MainActor
            func record(_ id: String, _ outcome: StepResult.Outcome, _ detail: String) {
                guard var run = self.currentRunRecord,
                      let index = run.steps.firstIndex(where: { $0.id == id }) else { return }
                run.steps[index] = .init(id: id, name: run.steps[index].name, outcome: outcome, detail: detail)
                self.currentRunRecord = run
                self.lastRunResults = run.steps
                switch outcome {
                case .running: self.markStepRunning(id)
                case .success: self.markStepDone(id, succeeded: true)
                case .failed: self.markStepDone(id, succeeded: false)
                case .interrupted: self.markStepInterrupted(id)
                case .warning: self.markStepWarning(id)
                default: break
                }
            }
            do {
                self.workflowState = .preflight
                record("validate", .running, "Verifying bundle, home, and exact sandbox profile.")
                let requestedHome = self.homeDirectoryProvider()
                guard let normalized = ShellCommands.normalizedSafeHomeDirectory(requestedHome) else {
                    throw self.appError("Sandbox launch refused: invalid home directory.")
                }
                let home = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardized.path
                var directory: ObjCBool = false
                guard ShellCommands.isSafeHomeDirectory(home),
                      FileManager.default.fileExists(atPath: home, isDirectory: &directory), directory.boolValue else {
                    throw self.appError("Sandbox launch requires a safe existing home directory.")
                }
                _ = try await self.verifiedZoomBundle()
                _ = try await self.runProcess(stepName: "Validate Zoom sandbox profile", executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: home)], timeout: 15)
                record("validate", .success, "Verified bundle and required sandbox profile.")

                activeID = "closeZoom"
                self.workflowState = .closingZoom
                record(activeID, .running, "Closing this user's Zoom processes.")
                _ = try await self.runProcess(stepName: "Close Zoom", executable: Constants.bashPath, arguments: ["-c", self.stopZoomCommand])
                record(activeID, .success, "This user's existing Zoom processes closed.")

                activeID = "mediaAccess"
                self.workflowState = .checkingMediaAccess
                record(activeID, .running, "Checking camera and microphone access.")
                do {
                    let detail = try await self.ensureMediaAccessForSandboxedZoom()
                    record(activeID, .success, detail)
                } catch {
                    try Task.checkCancellation()
                    record(activeID, .warning, error.localizedDescription)
                }

                activeID = "launch"
                self.workflowState = .launchingZoom
                record(activeID, .running, "Launching verified Zoom inside the required sandbox.")
                let verified = try await self.verifiedZoomBundle()
                let output = try await self.runProcess(stepName: "Launch Zoom", executable: Constants.bashPath,
                    arguments: ["-c", ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: verified.binaryPath,
                        homeDirectory: home, verifiedAppPath: verified.appPath)], timeout: 120)
                record(activeID, .success, output)
                if var run = self.currentRunRecord {
                    run.outcome = run.steps.contains { $0.outcome == .warning } ? .completedWithWarnings : .succeeded
                    run.finishedAt = Date()
                    self.currentRunRecord = run
                }
                return "Sandbox-only launch finished. No backup, reset, network change, or administrator DNS operation was requested. Independently starting normal Zoom bypasses this launcher's protection."
            } catch {
                let cancelled = error is CancellationError || Task.isCancelled
                record(activeID, cancelled ? .interrupted : .failed, error.localizedDescription)
                if var run = self.currentRunRecord {
                    run.outcome = cancelled ? .cancelled : .failed
                    run.failureMessage = cancelled ? nil : error.localizedDescription
                    run.failedStepID = activeID
                    run.finishedAt = Date()
                    self.currentRunRecord = run
                }
                if cancelled { throw CancellationError() }
                throw error
            }
        }
    }

    func startZoom() {
        guard canStartZoom else {
            appendLog(hasUnsettledPrivilegedOperation ? PrivilegedOperationGuard.recoveryMessage : "Start Zoom is unavailable until required preflight checks pass.")
            return
        }

        let requestedHomeDirectory = homeDirectoryProvider()
        let normalizedHomeDirectory = ShellCommands.normalizedSafeHomeDirectory(requestedHomeDirectory)
        let homeDirectory = normalizedHomeDirectory.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardized.path
        } ?? requestedHomeDirectory

        let canonicalSpecs = RepairStepSpec.canonicalSteps(macSpoofingDisabled: networkEnvironment().osMajor >= 14)
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
                    guard self.backupVerifier(backupPath, homeDirectory) else {
                        throw self.appError("Backup verification failed: '\(backupPath)' is not a valid recovery snapshot on disk.")
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
                let networkStepName = self.networkEnvironment().osMajor >= 14 ? "Network Check" : "MAC Spoof & Network"
                self.workflowState = self.networkEnvironment().osMajor >= 14 ? .checkingNetwork : .spoofingMAC
                beginStep("network")
                self.appendLog(ShellCommands.isMacSpoofingDisabledForCurrentOS()
                    ? "Step: Check active network; legacy MAC spoofing is disabled on macOS 14+"
                    : "Step: Spoof MAC and reconnect active network (admin prompt expected)")
                var precomputedDNSResult: PrivilegedDNSResult?
                @MainActor
                func recordDNS(_ dns: PrivilegedDNSResult) {
                    precomputedDNSResult = dns
                    if dns.succeeded { self.markStepDone("dns", succeeded: true) }
                    else { self.markStepWarning("dns") }
                    finishStep(.init(id: "dns", name: "DNS Flush", outcome: dns.succeeded ? .success : .warning,
                        detail: dns.detail.isEmpty ? "DNS operation completed during the combined administrator step." : dns.detail))
                }
                do {
                    let networkResult = try await self.spoofMACAndReconnectActiveInterface(
                        onPrivilegedDNSResult: { recordDNS($0) }
                    )
                    if let dnsResult = networkResult.dnsResult {
                        recordDNS(dnsResult)
                    }
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
                    if self.privilegedOperationNeedsSettlement {
                        self.markStepDone("network", succeeded: false)
                        finishStep(.init(id: "network", name: networkStepName, outcome: .failed, detail: PrivilegedOperationGuard.recoveryMessage))
                        throw self.appError(PrivilegedOperationGuard.recoveryMessage)
                    }
                    if error is CancellationError { throw error }
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
                    try OperationStatus.requireSuccess(in: output, marker: "__1132_RESET_STATUS__")
                    let detail = lines.filter { !$0.hasPrefix("__1132_") }.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.markStepDone("resetData", succeeded: true)
                    finishStep(.init(
                        id: "resetData",
                        name: "Clear Local State",
                        outcome: .success,
                        detail: detail.isEmpty ? "Cleared the listed Zoom state and local logs." : detail
                    ))
                } catch {
                    try Task.checkCancellation()
                    self.markStepDone("resetData", succeeded: false)
                    finishStep(.init(id: "resetData", name: "Clear Local State", outcome: .failed, detail: error.localizedDescription))
                    throw self.appError("Reset failed. Zoom was not launched. Earlier network/DNS changes may remain; no rollback was performed. Backup: \(runCreatedBackup ?? "unavailable"). \(error.localizedDescription)")
                }

                // 6. DNS flush.
                self.workflowState = .flushingDNS
                beginStep("dns")
                if let precomputedDNSResult {
                    self.appendLog("Step: Refresh DNS cache (completed during single administrator session)")
                    let dnsSucceeded = precomputedDNSResult.succeeded
                    let detail = precomputedDNSResult.detail
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
                    if !dnsSucceeded && !detail.isEmpty {
                        self.appendLog("Warning: \(detail)")
                    }
                } else {
                    self.appendLog("Step: Refresh DNS cache (admin prompt may appear)")
                    do {
                        let script = ShellCommands.makePrivilegedCommand(ShellCommands.makeRefreshDNSCommand(), policy: .dns)
                        let output = try await self.runProcess(
                            stepName: "Refresh DNS cache",
                            executable: Constants.osascriptPath,
                            arguments: ["-e", script],
                            timeout: PrivilegedTimeoutPolicy.dns.processTimeout
                        )
                        let lines = output.components(separatedBy: .newlines)
                        let dnsSucceeded = OperationStatus.value(in: output, marker: "__1132_DNS_STATUS__") == 0
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
                        if self.privilegedOperationNeedsSettlement {
                            self.markStepDone("dns", succeeded: false)
                            finishStep(.init(id: "dns", name: "DNS Flush", outcome: .failed, detail: PrivilegedOperationGuard.recoveryMessage))
                            throw self.appError(PrivilegedOperationGuard.recoveryMessage)
                        }
                        if error is CancellationError { throw error }
                        try Task.checkCancellation()
                        self.markStepWarning("dns")
                        finishStep(.init(id: "dns", name: "DNS Flush", outcome: .warning, detail: error.localizedDescription))
                        self.appendLog("Warning: \(error.localizedDescription)")
                    }
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
                    let verifiedBundle = try await self.verifiedZoomBundle()
                    let output = try await self.runProcess(
                        stepName: "Launch Zoom",
                        executable: Constants.bashPath,
                        arguments: ["-c", ShellCommands.makeLaunchZoomCommand(
                            zoomBinaryPath: verifiedBundle.binaryPath,
                            homeDirectory: homeDirectory,
                            verifiedAppPath: verifiedBundle.appPath
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
                if Task.isCancelled && !self.privilegedOperationNeedsSettlement {
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

    private func finalizeRunRecordOnTermination(wasCancelled: Bool, message: String?) {
        guard var run = currentRunRecord, run.outcome == .running || run.outcome == .stopping else { return }
        let activeID = run.steps.first { $0.outcome == .running }?.id
        run.steps = run.steps.map { step in
            guard step.outcome == .running else { return step }
            return .init(id: step.id, name: step.name, outcome: wasCancelled ? .interrupted : .failed, detail: message ?? "Stopped by user; effects may be partial.")
        }
        run.outcome = wasCancelled ? .cancelled : .failed
        run.failedStepID = activeID
        run.failureMessage = message
        run.finishedAt = Date()
        currentRunRecord = run
        lastRunResults = run.steps
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
        guard !isRunning, !isOperationGateActive else {
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
                arguments: ["-c", ShellCommands.makeZoomRunningCheckCommand()]
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
                    let capability = NetworkCapability.resolve(environment: self.networkEnvironment(), interface: kind)
                    results.append("Network identity: \(capability.explanation)")
                    strategyDetail += " — " + capability.explanation
                    networkOutcome = capability.mechanism == .legacyAttempt ? .skipped : .warning
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

            if let validateFailure {
                syncRunRecord(outcome: .failed, failureMessage: validateFailure, failedStepID: "validate")
                throw self.appError("Preview validation failed: \(validateFailure). No repair changes were made.")
            }
            let hasAdvisories = completedResults.contains { $0.outcome == .warning }
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
                let capability = NetworkCapability.resolve(environment: self.networkEnvironment(), interface: activeInterfaceKind)
                checks.append(.init(id: "macspoof", label: "Network Identity", value: capability.explanation,
                    isWarning: capability.mechanism != .legacyAttempt))
            } else {
                checks.append(.init(id: "macspoof", label: "Network Identity", value: "Could not determine", isWarning: true))
            }

            let camera = Self.mediaAccessPreflightValue(for: .video)
            checks.append(.init(id: "camera", label: "Camera", value: camera.value, isWarning: camera.isWarning))
            let microphone = Self.mediaAccessPreflightValue(for: .audio)
            checks.append(.init(id: "microphone", label: "Microphone", value: microphone.value, isWarning: microphone.isWarning))

            if self.hasUnsettledPrivilegedOperation {
                checks.append(.init(id: "privileged-settlement", label: "Administrator operation", value: PrivilegedOperationGuard.recoveryMessage, isWarning: true, isBlocking: true))
            }

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
        let selectedPath = DiagnosticsCollector.sanitizedForSharing(zoomAppPath)
        let readinessText = "\(readinessSnapshot.state.badgeLabel) — \(DiagnosticsCollector.sanitizedForSharing(readinessSnapshot.headline))"
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

        let rawSystemInfo = """
App version: \(appVersion)
OS: \(osVersion)
Architecture: \(architecture)
Timestamp: \(timestamp)
Selected Zoom path: \(selectedPath)
Readiness: \(readinessText)
Last action status: \(lastStatus)
"""
        let systemInfo = DiagnosticsCollector.sanitizedForSharing(rawSystemInfo)
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

        let content = DiagnosticsCollector.sanitizedForSharing(lines.joined(separator: "\n"))
        return (Self.diagnosticsFileName, content)
    }

    private func runTask(
        _ title: String,
        action: @escaping () async throws -> String
    ) {
        guard !isRunning, !privilegedGuard.requiresSettlement else {
            privilegedOperationNeedsSettlement = privilegedGuard.requiresSettlement
            appendLog("Another task is already running.")
            return
        }

        guard privilegedGuard.acquireWorkflowOwnership() else {
            let message = "Another app instance owns the workflow, or the private workflow lock is unavailable."
            workflowState = .failed(message)
            finalizeProgressOnTermination(wasCancelled: false)
            finalizeRunRecordOnTermination(wasCancelled: false, message: message)
            appendLog(message)
            return
        }
        guard !privilegedGuard.requiresSettlement else {
            privilegedGuard.releaseWorkflowOwnership()
            privilegedOperationNeedsSettlement = true
            workflowState = .failed(PrivilegedOperationGuard.recoveryMessage)
            finalizeRunRecordOnTermination(wasCancelled: false, message: PrivilegedOperationGuard.recoveryMessage)
            return
        }

        guard let runID = runGate.begin() else {
            privilegedGuard.releaseWorkflowOwnership()
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
                    if !privilegedGuard.requiresSettlement { privilegedGuard.releaseWorkflowOwnership() }
                    appendLog("Timing: \(title) finished in \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
                    isRunning = false
                    isCanceling = false
                    isExecutingPrivilegedStep = false
                    runningTask = nil
                    if refreshPreflightAfterRun {
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
                let hasWarnings = currentRunRecord?.outcome == .completedWithWarnings
                workflowState = hasWarnings ? .completedWithWarnings : .completed
                appendLog(hasWarnings ? "=== Completed with warnings ===" : "=== Completed ===")
            } catch is CancellationError {
                workflowState = .canceled
                finalizeProgressOnTermination(wasCancelled: true)
                finalizeRunRecordOnTermination(wasCancelled: true, message: nil)
                appendLog("=== Cancelled; earlier effects remain recorded ===")
            } catch {
                if Task.isCancelled && !privilegedOperationNeedsSettlement {
                    workflowState = .canceled
                    finalizeProgressOnTermination(wasCancelled: true)
                    finalizeRunRecordOnTermination(wasCancelled: true, message: nil)
                    appendLog("=== Cancelled; earlier effects remain recorded ===")
                    return
                }
                workflowState = .failed(error.localizedDescription)
                finalizeProgressOnTermination(wasCancelled: false)
                finalizeRunRecordOnTermination(wasCancelled: false, message: error.localizedDescription)
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

    private func spoofMACAndReconnectActiveInterface(
        onPrivilegedDNSResult: ((PrivilegedDNSResult) -> Void)? = nil
    ) async throws -> MACSpoofResult {
        let interface = try await resolveActiveSupportedInterface()

        let capability = NetworkCapability.resolve(environment: networkEnvironment(), interface: interface.kind == .wifi ? .wifi : .ethernet)
        guard capability.mechanism == .legacyAttempt else {
            return MACSpoofResult(summary: capability.explanation, hasWarning: true, wasSkipped: true)
        }
        let previousOutput = (try? await runProcess(stepName: "Read current MAC address", executable: Constants.bashPath,
            arguments: ["-c", ShellCommands.makeVerifyMACCommand(device: interface.device)])) ?? ""
        let previousMAC = ShellCommands.normalizedMACAddress(previousOutput)

        let spoofedMAC = try ShellCommands.generateRandomMACAddress()
        let spoofScript = ShellCommands.makeSpoofAndDNSCommand(
            device: interface.device,
            spoofedMAC: spoofedMAC,
            networkService: interface.networkService,
            includeDNSFlush: true
        )

        appendLog("Network recovery: commands to be attempted on \(interface.device) (service: \(interface.networkService))")

        let appleScript = ShellCommands.makePrivilegedCommand(spoofScript, policy: .network)
        let commandOutput: String
        do {
            commandOutput = try await runProcess(
                stepName: "Spoof MAC and reconnect \(interface.kind.rawValue)",
                executable: Constants.osascriptPath,
                arguments: ["-e", appleScript],
                timeout: PrivilegedTimeoutPolicy.network.processTimeout
            )
        } catch {
            if error is CancellationError { throw error }
            if privilegedOperationNeedsSettlement {
                let dnsSucceeded = lastPrivilegedOutput.flatMap { OperationStatus.value(in: $0, marker: "__1132_DNS_STATUS__") } == 0
                onPrivilegedDNSResult?(PrivilegedDNSResult(succeeded: dnsSucceeded,
                    detail: dnsSucceeded ? "DNS reported success during the combined administrator step; overall privileged lifecycle remains indeterminate."
                        : "DNS may have run during the combined administrator step; its completion is unverified."))
                throw error
            }
            try Task.checkCancellation()
            onPrivilegedDNSResult?(PrivilegedDNSResult(succeeded: false, detail: error.localizedDescription))
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

        let outputLines = commandOutput.components(separatedBy: .newlines)
        let dnsSucceeded = OperationStatus.value(in: commandOutput, marker: "__1132_DNS_STATUS__") == 0
        let spoofSentinelIndex = outputLines.firstIndex(where: { $0.hasPrefix("__1132_SPOOF_STATUS__=") })
        let nonSentinelCommandOutput: String
        let dnsOutput: String
        if let spoofSentinelIndex {
            nonSentinelCommandOutput = outputLines[..<spoofSentinelIndex]
                .filter { !$0.hasPrefix("__1132_") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            dnsOutput = outputLines[(spoofSentinelIndex + 1)...]
                .filter { !$0.hasPrefix("__1132_") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let combinedNonSentinel = outputLines
                .filter { !$0.hasPrefix("__1132_") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            nonSentinelCommandOutput = combinedNonSentinel
            dnsOutput = dnsSucceeded ? "" : combinedNonSentinel
        }
        let dnsResult = PrivilegedDNSResult(succeeded: dnsSucceeded, detail: dnsOutput)
        onPrivilegedDNSResult?(dnsResult)

        try OperationStatus.requireSuccess(in: commandOutput, marker: "__1132_SPOOF_STATUS__")
        try Task.checkCancellation()

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
            summary = "Requested MAC observed on \(interface.kind.rawValue) (\(interface.device), service: \(interface.networkService)) -> \(spoofedMAC); network service restarted"
        } else {
            let detail = actualMAC.map {
                "Current MAC (\($0)) does not match target (\(spoofedMAC))."
            } ?? "Could not read the current MAC address after spoofing."
            appendLog("Network recovery: MAC change was not applied. Commands attempted:")
            appendLog("  \(spoofScript)")
            let warning = "MAC address change was not verified on \(interface.kind.rawValue) (\(interface.device)). \(detail) Driver support varies; changing networks does not establish that error 1132 is resolved. If connectivity is disrupted, reconnect using System Settings > Network."
            warnings.append(warning)
            summary = warning
        }

        let recoveryWarning = try await verifyNetworkRecovered(expectedDevice: interface.device)
        if let recoveryWarning {
            warnings.append(recoveryWarning)
        }

        let observation = NetworkIdentityObservation(reconnected: recoveryWarning == nil,
            previousAddress: previousMAC, currentAddress: actualMAC, verifiedMode: nil)
        if observation.addressChanged != true {
            warnings.append(observation.addressChanged == false ? "The address did not change." : "The address change could not be established.")
        }
        var summaryParts = [summary, observation.summary]

        if !nonSentinelCommandOutput.isEmpty {
            summaryParts.append(nonSentinelCommandOutput)
        }
        for warning in warnings where warning != summary {
            summaryParts.append(warning)
        }
        let combinedSummary = summaryParts.joined(separator: "\n")

        return MACSpoofResult(
            summary: combinedSummary,
            hasWarning: !warnings.isEmpty,
            wasSkipped: false,
            dnsResult: dnsResult
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
        let verified = try await verifiedZoomBundle()
        return verified.binaryPath
    }

    private func verifiedZoomBundle() async throws -> ZoomBundleVerifier.VerifiedBundle {
        let appPath = zoomAppPath
        if let verifier = bundleVerifierOverride {
            let verified = try await Task.detached(priority: .userInitiated) {
                try verifier(appPath)
            }.value
            return verified
        }
        let verified = try await zoomVerifier(appPath)
        return verified
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
            guard !privilegedGuard.requiresSettlement else { throw appError(PrivilegedOperationGuard.recoveryMessage) }
            lastPrivilegedOutput = nil
            guard privilegedGuard.begin() else {
                privilegedOperationNeedsSettlement = true
                throw appError("Cannot persist administrator-operation ownership. " + PrivilegedOperationGuard.recoveryMessage)
            }
            isExecutingPrivilegedStep = true
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        defer {
            if isPrivileged {
                isExecutingPrivilegedStep = false
                privilegedOperationNeedsSettlement = privilegedGuard.requiresSettlement
            }
            appendLog("Timing: \(stepName) took \(Self.formatElapsed(startedAt.duration(to: clock.now))).")
        }

        do {
            let result: ProcessExecutionResult
            if isPrivileged {
                let executor = processExecutor
                let override = processExecutorOverride
                result = try await Task.detached(priority: .userInitiated) {
                    if let override {
                        let output = try await override(stepName, executable, arguments, timeout)
                        return ProcessExecutionResult(exitCode: 0, standardOutput: output, standardError: "", outputWasTruncated: false)
                    }
                    return try await executor.run(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        maxOutputBytes: BoundedProcessExecutor.defaultMaxOutputBytes
                    )
                }.value
            } else if let override = processExecutorOverride {
                return try await override(stepName, executable, arguments, timeout)
            } else {
                result = try await processExecutor.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    maxOutputBytes: BoundedProcessExecutor.defaultMaxOutputBytes
                )
            }
            let output = result.combinedOutput
            if isPrivileged {
                lastPrivilegedOutput = output
                if OperationStatus.value(in: output, marker: "__1132_PRIVILEGED_COMPLETE__") != nil {
                    privilegedGuard.settle(.completed)
                } else if result.exitCode == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "__1132_AUTH_CANCELLED__=0" {
                    privilegedGuard.settle(.cancelled)
                    throw CancellationError()
                } else {
                    throw appError(PrivilegedOperationGuard.recoveryMessage)
                }
                // Let the caller record completed network/DNS effects before honoring UI cancellation.
            } else {
                try Task.checkCancellation()
            }
            guard result.exitCode == 0 else {
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let message: String
                if !trimmedOutput.isEmpty {
                    message = "\(stepName): \(trimmedOutput)"
                } else {
                    message = "\(stepName): Command failed with exit code \(result.exitCode)."
                }
                throw AppError.processFailed(exitCode: Int(result.exitCode), message: message)
            }
            return output
        } catch let error as ProcessExecutionError {
            if isPrivileged {
                if case .launchFailed = error {
                    privilegedGuard.settle(.cancelled)
                } else {
                    throw appError(PrivilegedOperationGuard.recoveryMessage)
                }
            }
            if case .timedOut = error {
                appendLog("Timeout: '\(stepName)' did not complete within \(Int(timeout))s.")
                throw AppError.processTimeout("\(stepName): Timed out after \(Int(timeout)) seconds.")
            }
            throw error
        } catch {
            if isPrivileged && privilegedGuard.requiresSettlement {
                throw appError(PrivilegedOperationGuard.recoveryMessage)
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

    func applyUIFixture(named fixtureName: String, appVersion: String = AppConfiguration.appVersion) {
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
            .init(id: "macspoof", label: "Network Identity", value: "Manual Private Wi-Fi Address settings; automatic mode control unverified", isWarning: true),
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
                    return StepResult(id: spec.id, name: spec.name, outcome: .warning, detail: "Automatic address change unavailable; network settings unchanged.")
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
