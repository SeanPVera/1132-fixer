import Foundation
import Testing
@testable import _132Fixer

@Suite("Design system token parity")
struct ThemeTokenParityTests {
    @Test func swiftThemeMatchesCanonicalMacOSTokensJSON() throws {
        #expect(Theme.Colors.hexTokens["primary"] == "#235FA8")
        #expect(Theme.Colors.hexTokens["border-control"] == "#718399")
        #expect(Theme.Colors.hexTokens["focus"] == "#8DBCF2")
        #expect(Theme.Window.defaultWidth == 900)
        #expect(Theme.Window.defaultHeight == 760)
        #expect(Theme.Window.minimumWidth == 720)
        #expect(Theme.Window.minimumHeight == 640)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tokenURL = repoRoot.appendingPathComponent("design-system/tokens/macos.json")
        guard FileManager.default.fileExists(atPath: tokenURL.path) else {
            return
        }
        let data = try Data(contentsOf: tokenURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let colorSection = try #require(json["colors"] as? [String: String])
        for (tokenName, expectedHex) in Theme.Colors.hexTokens {
            let value = try #require(colorSection[tokenName], "Missing color token \(tokenName) in macos.json")
            #expect(value.uppercased() == expectedHex.uppercased(), "Color mismatch for \(tokenName)")
        }

        let typographySection = try #require(json["typography"] as? [String: Any])
        #expect(typographySection["font-family-sans"] as? String == Theme.Typography.fontFamilySans)
        #expect(typographySection["font-family-mono"] as? String == Theme.Typography.fontFamilyMono)
        let rolesSection = try #require(typographySection["roles"] as? [String: [String: Any]])
        for (roleName, spec) in Theme.Typography.roleSpecs {
            let entry = try #require(rolesSection[roleName], "Missing typography role \(roleName) in macos.json")
            let size = try #require(entry["size"] as? Double)
            let lineHeight = try #require(entry["lineHeight"] as? Double)
            let weight = try #require(entry["weight"] as? Int)
            let family = try #require(entry["family"] as? String)
            #expect(CGFloat(size) == spec.size, "Font size mismatch for \(roleName)")
            #expect(CGFloat(lineHeight) == spec.lineHeight, "Line height mismatch for \(roleName)")
            #expect(weight == spec.weight, "Weight mismatch for \(roleName)")
            #expect(family == spec.family, "Family mismatch for \(roleName)")
        }

        let spacingSection = try #require(json["spacing"] as? [String: Double])
        #expect(CGFloat(try #require(spacingSection["4"])) == Theme.Spacing.s4)
        #expect(CGFloat(try #require(spacingSection["8"])) == Theme.Spacing.s8)
        #expect(CGFloat(try #require(spacingSection["12"])) == Theme.Spacing.s12)
        #expect(CGFloat(try #require(spacingSection["16"])) == Theme.Spacing.s16)
        #expect(CGFloat(try #require(spacingSection["24"])) == Theme.Spacing.s24)
        #expect(CGFloat(try #require(spacingSection["32"])) == Theme.Spacing.s32)
        #expect(CGFloat(try #require(spacingSection["48"])) == Theme.Spacing.s48)
        #expect(CGFloat(try #require(spacingSection["64"])) == Theme.Spacing.s64)
        #expect(CGFloat(try #require(spacingSection["outerMargin"])) == Theme.Spacing.outerMargin)

        let radiusSection = try #require(json["radius"] as? [String: Double])
        #expect(CGFloat(try #require(radiusSection["row"])) == Theme.Radius.row)
        #expect(CGFloat(try #require(radiusSection["control"])) == Theme.Radius.control)

        let focusSection = try #require(json["focus"] as? [String: Double])
        #expect(CGFloat(try #require(focusSection["ringWidth"])) == Theme.Focus.ringWidth)
        #expect(CGFloat(try #require(focusSection["ringGap"])) == Theme.Focus.ringGap)

        let motionSection = try #require(json["motion"] as? [String: Int])
        #expect(try #require(motionSection["controlFeedbackMs"]) == Theme.Motion.controlFeedbackMs)
        #expect(try #require(motionSection["disclosureMs"]) == Theme.Motion.disclosureMs)

        let windowSection = try #require(json["window"] as? [String: Any])
        let defaultDims = try #require(windowSection["default"] as? [Double])
        let minDims = try #require(windowSection["minimum"] as? [Double])
        #expect(CGFloat(defaultDims[0]) == Theme.Window.defaultWidth)
        #expect(CGFloat(defaultDims[1]) == Theme.Window.defaultHeight)
        #expect(CGFloat(minDims[0]) == Theme.Window.minimumWidth)
        #expect(CGFloat(minDims[1]) == Theme.Window.minimumHeight)
        #expect(CGFloat(try #require(windowSection["contentMaxWidth"] as? Double)) == Theme.Window.contentMaxWidth)
        #expect(CGFloat(try #require(windowSection["recordFourColumnMinWidth"] as? Double)) == Theme.Window.recordFourColumnMinWidth)
        #expect(CGFloat(try #require(windowSection["rowMinHeight"] as? Double)) == Theme.Window.rowMinHeight)
    }
}

@Suite("Workflow run ownership")
struct WorkflowRunGateTests {
    @Test func rejectsOverlapAndIgnoresStaleCompletion() throws {
        var gate = WorkflowRunGate()
        let firstCandidate = gate.begin()
        let first = try #require(firstCandidate)

        #expect(gate.isActive)
        let overlappingRun = gate.begin()
        #expect(overlappingRun == nil)
        let staleCompletion = gate.finish(UUID())
        #expect(!staleCompletion)
        #expect(gate.isActive)
        let activeCompletion = gate.finish(first)
        #expect(activeCompletion)
        #expect(!gate.isActive)
        let secondRun = gate.begin()
        #expect(secondRun != nil)
    }
}

@Suite("Workflow results and state model")
@MainActor
struct WorkflowResultFormatterTests {
    @Test func summaryDoesNotDescribeSkippedOrWarningStepsAsSuccess() {
        let results = [
            AppViewModel.StepResult(id: "safety", name: "Safety Check", outcome: .success),
            AppViewModel.StepResult(id: "network", name: "Network Check", outcome: .skipped, detail: "Unsupported"),
            AppViewModel.StepResult(id: "dns", name: "DNS Flush", outcome: .warning, detail: "Authorization canceled"),
        ]

        let summary = WorkflowResultFormatter.summary(for: results)

        #expect(summary.contains("Completed with attention needed: Network Check, DNS Flush"))
        #expect(summary.contains("[SKIP] Network Check"))
        #expect(summary.contains("[WARN] DNS Flush"))
        #expect(!summary.contains("All steps completed successfully"))
    }

    @Test func outcomeLabelsRemainDistinctIncludingInterruptedAndUnstarted() {
        #expect(AppViewModel.StepResult.Outcome.success.label == "OK")
        #expect(AppViewModel.StepResult.Outcome.warning.label == "WARN")
        #expect(AppViewModel.StepResult.Outcome.skipped.label == "SKIP")
        #expect(AppViewModel.StepResult.Outcome.failed.label == "FAIL")
        #expect(AppViewModel.StepResult.Outcome.interrupted.label == "STOP")
        #expect(AppViewModel.StepResult.Outcome.unstarted.label == "PEND")
        #expect(AppViewModel.StepResult.Outcome.running.label == "RUN")
    }

    @Test func startRequiresReadyNonblockingPreflight() {
        let viewModel = AppViewModel()
        #expect(!viewModel.canStartZoom)

        viewModel.preflight = .init(status: .ready, checks: [
            .init(id: "warning", label: "Network Identity", value: "Unavailable", isWarning: true),
        ])
        #expect(viewModel.canStartZoom)

        viewModel.preflight = .init(status: .ready, checks: [
            .init(id: "zoom", label: "Zoom App", value: "Invalid signature", isWarning: true, isBlocking: true),
        ])
        #expect(!viewModel.canStartZoom)
    }

    @Test func canonicalStepsPlaceValidationCloseZoomAndBackupBeforeAnyMutation() {
        let steps = RepairStepSpec.canonicalSteps()
        #expect(steps.count == 9)
        #expect(steps.map(\.id) == [
            "validate",
            "closeZoom",
            "backup",
            "network",
            "resetData",
            "dns",
            "updaters",
            "mediaAccess",
            "launch",
        ])
        #expect(steps[0].requiresAdmin == false)
        #expect(steps[1].requiresAdmin == false)
        #expect(steps[2].requiresAdmin == false)
        #expect(steps[3].requiresAdmin == true)
        #expect(steps[4].requiresAdmin == false)
        #expect(steps[5].requiresAdmin == true)
    }

    @Test func repairPlanListsSavedApplicationStateAndLogsInAffectedLocations() {
        let plan = RepairPlan.build(
            readiness: .initial(selectedAppPath: "/Applications/zoom.us.app", isCustomLocation: false),
            selectedAppPath: "/Applications/zoom.us.app",
            isCustomLocation: false
        )
        let dataLoc = plan.affectedLocations.first(where: { $0.id == "user-zoom-data" })
        let logsLoc = plan.affectedLocations.first(where: { $0.id == "user-zoom-logs" })

        #expect(dataLoc?.path.contains("~/Library/Saved Application State/us.zoom.xos.savedState") == true)
        #expect(logsLoc?.path == "~/Library/Logs/zoom.us.log*")
    }
}

@Suite("Execution ordering, privileged cancellation, and backup provenance", .serialized)
@MainActor
struct WorkflowExecutionSemanticsTests {
    private static func makeReadyPreflight() -> AppViewModel.PreflightInfo {
        .init(
            status: .ready,
            checks: [
                .init(id: "arch", label: "Architecture", value: "arm64 (Supported)", isWarning: false),
                .init(id: "os", label: "macOS", value: "14.5 (Supported)", isWarning: false),
                .init(id: "zoom", label: "Zoom App", value: "Verified at /Applications/zoom.us.app", isWarning: false),
                .init(id: "network", label: "Network", value: "Wi-Fi (en0)", isWarning: false),
                .init(id: "mac", label: "Network Identity", value: "Private Wi-Fi address rotation", isWarning: false),
                .init(id: "disk", label: "Backup Space", value: "42 GB available", isWarning: false),
                .init(id: "sandbox", label: "Sandbox", value: "sandbox-exec ready", isWarning: false),
            ]
        )
    }

    @Test func failureBeforeBackupPreservesPreviousBackupPathWithoutClaimingCurrentRunCreatedIt() async throws {
        let commandLog = LockedArray<String>()
        let runner: AppViewModel.ProcessExecutor = { stepName, _, _, _ in
            commandLog.append(stepName)
            if stepName == "Close Zoom" {
                throw NSError(
                    domain: AppViewModel.Constants.errorDomain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Zoom refused to close after SIGTERM and SIGKILL."]
                )
            }
            return "ok"
        }
        let verifier: AppViewModel.BundleVerifier = { _ in
            ZoomBundleVerifier.VerifiedBundle(
                appPath: "/Applications/zoom.us.app",
                binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
            )
        }

        let olderBackup = "/Users/tester/Library/Application Support/1132Fixer/Backups/snapshot-older"
        let viewModel = AppViewModel(initialDiskBackupPath: olderBackup)
        viewModel.processExecutorOverride = runner
        viewModel.bundleVerifierOverride = verifier
        viewModel.preflight = Self.makeReadyPreflight()

        viewModel.startZoom()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Fail-closed: Backup, MAC spoof, data reset, DNS flush, updater unload, and launch must not run.
        #expect(commandLog.values == ["Validate Zoom sandbox profile", "Close Zoom"])
        #expect(viewModel.currentRunBackupPath == nil)
        #expect(viewModel.previousBackupPath == olderBackup)
        #expect(viewModel.currentRunRecord?.createdBackupPath == nil)
        #expect(viewModel.currentRunRecord?.outcome == RunRecord.Outcome.failed)

        let steps = try #require(viewModel.workflowProgress?.steps)
        #expect(steps.first(where: { $0.id == "validate" })?.state == AppViewModel.WorkflowProgress.StepState.succeeded)
        #expect(steps.first(where: { $0.id == "closeZoom" })?.state == AppViewModel.WorkflowProgress.StepState.failed)
        // Unrun steps after failure must remain .unstarted, never .skipped.
        for unrunID in ["backup", "network", "resetData", "dns", "updaters", "mediaAccess", "launch"] {
            #expect(steps.first(where: { $0.id == unrunID })?.state == AppViewModel.WorkflowProgress.StepState.unstarted)
        }
    }

    @Test func backupFailureBeforeDataResetAbortsBeforeAnyDeletionAndMarksStepFailed() async throws {
        let commandLog = LockedArray<String>()
        let runner: AppViewModel.ProcessExecutor = { stepName, _, _, _ in
            commandLog.append(stepName)
            if stepName == "Backup Zoom state" {
                throw NSError(
                    domain: AppViewModel.Constants.errorDomain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to back up ~/Library/Application Support/zoom.us; refusing to delete Zoom data."]
                )
            }
            return "ok"
        }
        let verifier: AppViewModel.BundleVerifier = { _ in
            ZoomBundleVerifier.VerifiedBundle(
                appPath: "/Applications/zoom.us.app",
                binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
            )
        }

        let priorBackup = "/Users/tester/Library/Application Support/1132Fixer/Backups/snapshot-prior"
        let viewModel = AppViewModel(initialDiskBackupPath: priorBackup)
        viewModel.processExecutorOverride = runner
        viewModel.bundleVerifierOverride = verifier
        viewModel.preflight = Self.makeReadyPreflight()

        viewModel.startZoom()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(commandLog.values == [
            "Validate Zoom sandbox profile",
            "Close Zoom",
            "Backup Zoom state",
        ])
        #expect(!commandLog.values.contains("Reset Zoom data"))
        #expect(viewModel.currentRunBackupPath == nil)
        #expect(viewModel.currentRunRecord?.createdBackupPath == nil)
        #expect(viewModel.previousBackupPath == priorBackup)
    }

    @Test func privilegedCancellationHoldsRunGateInStoppingStateUntilSubprocessExits() async throws {
        let gateSignal = AsyncGate()
        let commandLog = LockedArray<String>()

        let runner: AppViewModel.ProcessExecutor = { stepName, executable, _, _ in
            commandLog.append(stepName)
            if stepName == "Backup Zoom state" {
                return "/Users/tester/Library/Application Support/1132Fixer/Backups/snapshot-current"
            }
            if stepName == "Detect active network interface" {
                return "interface: en0"
            }
            if stepName == "Inspect hardware ports" {
                return "Hardware Port: Wi-Fi\nDevice: en0"
            }
            if stepName == "Inspect network services" {
                return "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)"
            }
            if stepName == "Read current MAC address" {
                return "aa:bb:cc:dd:ee:01"
            }
            if stepName == "Check Private Wi-Fi Address mode" {
                return "static"
            }
            if executable == "/usr/bin/osascript" {
                await gateSignal.enterAndWait()
                throw CancellationError()
            }
            return "ok"
        }
        let verifier: AppViewModel.BundleVerifier = { _ in
            ZoomBundleVerifier.VerifiedBundle(
                appPath: "/Applications/zoom.us.app",
                binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
            )
        }

        let viewModel = AppViewModel(initialDiskBackupPath: nil)
        viewModel.processExecutorOverride = runner
        viewModel.bundleVerifierOverride = verifier
        viewModel.preflight = Self.makeReadyPreflight()

        viewModel.startZoom()
        await gateSignal.waitUntilEntered()

        #expect(viewModel.isRunning)
        #expect(viewModel.isExecutingPrivilegedStep)

        // Request cancellation while privileged osascript step is still running.
        viewModel.cancelWorkflow()

        // Gate must remain held in Stopping… while the privileged helper is still alive.
        #expect(viewModel.isRunning)
        #expect(viewModel.isCanceling)
        #expect(viewModel.workflowState == AppViewModel.WorkflowState.canceling)
        #expect(viewModel.currentRunRecord?.outcome == RunRecord.Outcome.stopping)

        // Attempting to start another workflow while Stopping… must be rejected by the run gate.
        viewModel.dryRun()
        #expect(viewModel.logEntries.last?.message == "Another task is already running.")

        // Now release the privileged helper subprocess.
        await gateSignal.release()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!viewModel.isRunning)
        #expect(!viewModel.isCanceling)
        #expect(!viewModel.isExecutingPrivilegedStep)
        #expect(viewModel.workflowState == AppViewModel.WorkflowState.canceled)
        #expect(viewModel.currentRunRecord?.outcome == RunRecord.Outcome.cancelled)

        // Step 3 (Backup) succeeded before Step 4 (Network Identity) was interrupted.
        #expect(viewModel.currentRunBackupPath == "/Users/tester/Library/Application Support/1132Fixer/Backups/snapshot-current")
        #expect(viewModel.currentRunRecord?.createdBackupPath == "/Users/tester/Library/Application Support/1132Fixer/Backups/snapshot-current")

        let steps = try #require(viewModel.workflowProgress?.steps)
        #expect(steps.first(where: { $0.id == "validate" })?.state == AppViewModel.WorkflowProgress.StepState.succeeded)
        #expect(steps.first(where: { $0.id == "closeZoom" })?.state == AppViewModel.WorkflowProgress.StepState.succeeded)
        #expect(steps.first(where: { $0.id == "backup" })?.state == AppViewModel.WorkflowProgress.StepState.succeeded)
        #expect(steps.first(where: { $0.id == "network" })?.state == AppViewModel.WorkflowProgress.StepState.interrupted)
        for unrunID in ["resetData", "dns", "updaters", "mediaAccess", "launch"] {
            #expect(steps.first(where: { $0.id == unrunID })?.state == AppViewModel.WorkflowProgress.StepState.unstarted)
        }
    }

    @Test func dryRunReplacesStaleRunRecordWithPreviewLedger() async throws {
        let runner: AppViewModel.ProcessExecutor = { stepName, _, _, _ in
            switch stepName {
            case "Check Zoom process":
                return "stopped"
            case "Detect interface":
                return "interface: en0"
            case "Hardware ports":
                return "Hardware Port: Wi-Fi\nDevice: en0"
            default:
                return "ok"
            }
        }
        let verifier: AppViewModel.BundleVerifier = { _ in
            ZoomBundleVerifier.VerifiedBundle(
                appPath: "/Applications/zoom.us.app",
                binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us"
            )
        }

        let viewModel = AppViewModel(initialDiskBackupPath: nil)
        viewModel.processExecutorOverride = runner
        viewModel.bundleVerifierOverride = verifier
        viewModel.preflight = Self.makeReadyPreflight()
        viewModel.applyUIFixture(named: "failed_after_backup")
        #expect(viewModel.currentRunRecord?.title == "Repair Zoom 1132")
        #expect(viewModel.currentRunRecord?.outcome == RunRecord.Outcome.failed)

        viewModel.dryRun()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let record = try #require(viewModel.currentRunRecord)
        #expect(record.title == "Preview Steps (Dry Run)")
        #expect(record.createdBackupPath == nil)
        #expect(record.steps.first(where: { $0.id == "validate" })?.outcome == AppViewModel.StepResult.Outcome.success)
        #expect(record.steps.first(where: { $0.id == "closeZoom" })?.outcome == AppViewModel.StepResult.Outcome.skipped)
        #expect(record.steps.first(where: { $0.id == "backup" })?.outcome == AppViewModel.StepResult.Outcome.skipped)
        #expect(record.steps.first(where: { $0.id == "launch" })?.outcome == AppViewModel.StepResult.Outcome.skipped)
    }
}

@Suite("Activity log cap and monotonic sequence")
@MainActor
struct ActivityLogRetentionTests {
    @Test func logEntriesCapAtFiveThousandWhileSequenceAndRevisionContinueIncrementing() {
        let viewModel = AppViewModel()
        viewModel.clearLogs()
        let baseRevision = viewModel.logRevision

        let totalLines = AppViewModel.maxInMemoryLogEntries + 250
        for index in 1...totalLines {
            viewModel.logMessage("Diagnostic line \(index)")
        }

        #expect(viewModel.logEntries.count == AppViewModel.maxInMemoryLogEntries)
        #expect(viewModel.logs.count == AppViewModel.maxInMemoryLogEntries)
        #expect(viewModel.logRevision == baseRevision + UInt64(totalLines))
        #expect(viewModel.logEntries.first?.sequence == baseRevision + 251)
        #expect(viewModel.logEntries.last?.sequence == baseRevision + UInt64(totalLines))
        #expect(viewModel.logEntries.last?.message == "Diagnostic line \(totalLines)")
    }
}

@Suite("Bug report frozen snapshot and UTF-8 truncation")
@MainActor
struct BugReportDraftTests {
    @Test func truncateDiagnosticsUTF8NeverSplitsMultibyteCharactersAndCapsAtByteLimit() {
        // 4-byte emoji repeated so boundary falls inside a multi-byte UTF-8 sequence.
        let unit = "🔧Line-0123456789\n"
        let repeated = String(repeating: unit, count: 80_000)
        #expect(repeated.utf8.count > ReportDraft.maxAttachmentBytes)

        let truncated = ReportDraft.truncateDiagnosticsUTF8(
            repeated,
            maxBytes: ReportDraft.maxAttachmentBytes
        )
        #expect(truncated.wasTruncated)
        #expect(truncated.data.count <= ReportDraft.maxAttachmentBytes)
        #expect(truncated.text.utf8.count == truncated.data.count)
        #expect(String(data: truncated.data, encoding: .utf8) != nil)
        #expect(truncated.text.contains("[Truncated to fit"))
    }

    @Test func reportDraftSnapshotRemainsFrozenWhenLogsChangeAfterSheetOpens() async throws {
        let viewModel = AppViewModel()
        viewModel.clearLogs()
        viewModel.logMessage("Initial diagnostic entry before opening bug report")

        viewModel.openBugReportSheet(appVersion: "1.8.2")
        while viewModel.isPreparingReportDraft {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let capturedDraft = viewModel.activeReportDraft
        #expect(capturedDraft != nil)
        let initialAttachment = capturedDraft?.attachmentContent ?? ""
        #expect(initialAttachment.contains("Initial diagnostic entry before opening bug report"))

        // Append additional logs while the sheet is open; frozen draft must not mutate.
        viewModel.logMessage("Late log entry after sheet opened")
        #expect(viewModel.activeReportDraft?.attachmentContent == initialAttachment)
        #expect(viewModel.activeReportDraft?.attachmentContent.contains("Late log entry after sheet opened") == false)
    }

    @Test func overLimitDescriptionPreservesUserTextAndBlocksSubmissionWithExactCount() async throws {
        let viewModel = AppViewModel()
        viewModel.openBugReportSheet(appVersion: "1.8.2")
        while viewModel.isPreparingReportDraft {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let overLimitText = String(repeating: "a", count: ReportDraft.maxDescriptionCharacters + 17)
        viewModel.bugReportMessage = overLimitText

        // User text must never be silently truncated.
        #expect(viewModel.bugReportMessage.count == ReportDraft.maxDescriptionCharacters + 17)

        await viewModel.submitBugReport()
        #expect(viewModel.bugReportMessage == overLimitText)
        #expect(viewModel.bugReportError?.contains("17 characters") == true)
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor AsyncGate {
    private var hasEntered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        hasEntered = true
        for waiter in enterWaiters {
            waiter.resume()
        }
        enterWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { continuation in
            enterWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
