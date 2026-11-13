import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    private let appVersion = AppConfiguration.appVersion

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        GeometryReader { proxy in
            let showsSidebar = proxy.size.width >= WorkspaceLayoutMetrics.sidebarBreakpoint
            let mainColumnWidth = showsSidebar
                ? proxy.size.width - WorkspaceLayoutMetrics.sidebarWidth - 1
                : proxy.size.width
            let availableContentWidth = min(
                max(mainColumnWidth - (Theme.Spacing.outerPadding * 2), 0),
                Theme.Window.contentMaxWidth
            )
            let isCompactLedger = availableContentWidth < Theme.Window.wideLedgerBreakpoint
            let ledgerItems = RepairRecordLedgerView.makeItems(
                steps: viewModel.workflowProgress?.steps ?? [],
                stepResults: viewModel.lastRunResults ?? [],
                runRecord: viewModel.currentRunRecord
            )
            let stage = WorkspaceStage(workflowState: viewModel.workflowState, isRunning: viewModel.isRunning)

            HStack(spacing: 0) {
                if showsSidebar {
                    PreflightSidebar(
                        preflight: viewModel.preflight,
                        isRunning: viewModel.isRunning,
                        logCount: viewModel.logEntries.count,
                        isReportingBug: viewModel.isReportingBug,
                        zoomLocation: zoomLocationPanel,
                        onShowDetails: { viewModel.isShowingSystemChecksSheet = true },
                        onShowLog: { viewModel.isShowingActivityLogSheet = true },
                        onExportDiagnostics: { viewModel.exportDiagnostics(appVersion: appVersion) },
                        onReportBug: { viewModel.openBugReportSheet(appVersion: appVersion) }
                    )

                    Divider().overlay(Theme.Colors.border)
                }

                VStack(spacing: 0) {
                    masthead(ledgerItems: ledgerItems, stage: stage)

                    Divider().overlay(Theme.Colors.border)

                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.majorSection) {
                            if !showsSidebar {
                                zoomLocationPanel
                            }

                            if stage == .running {
                                LiveLogTail(
                                    entries: viewModel.logEntries,
                                    onOpenFullLog: { viewModel.isShowingActivityLogSheet = true }
                                )
                            }

                            VStack(alignment: .leading, spacing: Theme.Spacing.s12) {
                                RepairRecordLedgerView(
                                    items: ledgerItems,
                                    workflowState: viewModel.workflowState,
                                    runRecord: viewModel.currentRunRecord,
                                    expandedStepIDs: viewModel.expandedStepIDs,
                                    onToggleExpand: { stepID in
                                        if viewModel.expandedStepIDs.contains(stepID) {
                                            viewModel.expandedStepIDs.remove(stepID)
                                        } else {
                                            viewModel.expandedStepIDs.insert(stepID)
                                        }
                                    },
                                    isCompactLayout: isCompactLedger
                                )

                                BackupProvenanceBar(
                                    currentRunBackupPath: viewModel.currentRunBackupPath,
                                    previousBackupPath: viewModel.previousBackupPath,
                                    onRevealBackup: { viewModel.revealLatestBackup() }
                                )
                            }
                        }
                        .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.outerPadding)
                        .padding(.vertical, Theme.Spacing.majorSection)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }

                    bottomBar(showsSupportLinks: !showsSidebar)
                }
            }
            .background(Theme.Colors.background)
        }
        .frame(
            minWidth: Theme.Window.minWidth,
            idealWidth: Theme.Window.idealWidth,
            minHeight: Theme.Window.minHeight,
            idealHeight: Theme.Window.idealHeight
        )
        .preferredColorScheme(.dark)
        .tint(Theme.Colors.primary)
        .onAppear {
            if AppConfiguration.allowsDebugEnvironmentOverrides,
               ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"] != nil {
                viewModel.applyUIFixtureIfRequested(appVersion: appVersion)
            } else {
                viewModel.runPreflight()
            }
            configureWindowAndCaptureIfRequested()
        }
        .task {
            if !AppConfiguration.allowsDebugEnvironmentOverrides ||
               ProcessInfo.processInfo.environment["FIXER_UI_FIXTURE"] == nil {
                await viewModel.checkForUpdates(appVersion: appVersion)
            }
        }
        .alert("Update Available", isPresented: $viewModel.updateAlertIsPresented) {
            Button("View Release") {
                if let latestRelease = viewModel.latestRelease {
                    NSWorkspace.shared.open(latestRelease.htmlURL)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let release = viewModel.latestRelease {
                if let notes = release.releaseNotes, !notes.isEmpty {
                    Text("Version \(release.version) is available. You have \(appVersion).\n\n\(notes)")
                } else {
                    Text("Version \(release.version) is available. You have \(appVersion).")
                }
            } else {
                Text("A newer version is available.")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.activeRepairPlan != nil },
                set: { if !$0 { viewModel.dismissRepairPlan() } }
            )
        ) {
            if let plan = viewModel.activeRepairPlan {
                RepairConfirmationSheet(
                    plan: plan,
                    onCancel: { viewModel.dismissRepairPlan() },
                    onConfirm: { viewModel.confirmRepairPlanAndStart() }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingSystemChecksSheet) {
            SystemCheckDetailsSheet(
                preflight: viewModel.preflight,
                zoomAppPath: viewModel.zoomAppPath,
                isRunning: viewModel.isRunning,
                onRecheck: { viewModel.runPreflight() },
                onClose: { viewModel.isShowingSystemChecksSheet = false }
            )
        }
        .sheet(isPresented: $viewModel.isShowingActivityLogSheet) {
            ActivityLogSheet(
                viewModel: viewModel,
                appVersion: appVersion,
                onClose: { viewModel.isShowingActivityLogSheet = false }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.activeReportDraft != nil },
                set: { if !$0 { viewModel.closeBugReportSheet() } }
            )
        ) {
            if let draft = viewModel.activeReportDraft {
                BugReportFormSheet(
                    draft: draft,
                    email: $viewModel.bugReportEmail,
                    message: $viewModel.bugReportMessage,
                    submissionError: $viewModel.bugReportError,
                    isAttachmentPreviewExpanded: $viewModel.isAttachmentPreviewExpanded,
                    isSubmitting: viewModel.isReportingBug,
                    onSaveAttachment: { viewModel.saveReportDraftAttachment(draft) },
                    onCancel: { viewModel.closeBugReportSheet() },
                    onSubmit: {
                        Task {
                            await viewModel.submitBugReport()
                        }
                    }
                )
            }
        }
    }

    // MARK: - Pinned regions

    private var zoomLocationPanel: some View {
        ZoomLocationPanel(
            appPath: viewModel.zoomAppPath,
            isCustom: viewModel.customZoomAppPath != nil,
            isDisabled: viewModel.isRunning,
            installationNotice: viewModel.installationNotice,
            onChoose: { viewModel.chooseZoomLocation() },
            onReset: { viewModel.resetZoomLocation() },
            onDismissNotice: { viewModel.installationNotice = nil }
        )
    }

    /// Pinned stage header: identity, the serif status headline, and the stage's actions.
    /// Ready shows one focused primary action; Running shows state-derived progress and Stop;
    /// Results keeps the outcome with an integrated retry.
    private func masthead(ledgerItems: [RepairRecordLedgerView.LedgerStepItem], stage: WorkspaceStage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.groupedContent) {
            HeaderCard(
                appVersion: appVersion,
                latestRelease: viewModel.latestRelease
            )

            WorkspaceSummary(
                preflight: viewModel.preflight,
                workflowState: viewModel.workflowState,
                runRecord: viewModel.currentRunRecord,
                ledgerSteps: ledgerItems,
                isRunning: viewModel.isRunning,
                onRecheck: { viewModel.runPreflight() }
            )

            if stage == .running {
                HStack(alignment: .center, spacing: Theme.Spacing.s16) {
                    RunProgressStrip(
                        summary: RunProgressSummary(items: ledgerItems),
                        isCanceling: viewModel.isCanceling
                    )
                    footerActionButtons(stage: stage)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.s8) {
                        footerActionButtons(stage: stage)
                        Spacer(minLength: 0)
                    }
                    footerActionButtons(stage: stage, stacked: true)
                }
            }
        }
        .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.outerPadding)
        .padding(.top, Theme.Spacing.s16)
        .padding(.bottom, Theme.Spacing.majorSection)
        .frame(maxWidth: .infinity)
    }

    /// Guidance strip: what the actions will do or why they are unavailable. In the narrow
    /// single-column layout it also carries the support links the sidebar normally holds.
    private func bottomBar(showsSupportLinks: Bool) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.Colors.border)

            footerStatusText
                .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.outerPadding)
                .padding(.vertical, Theme.Spacing.s12)
                .frame(maxWidth: .infinity)

            if showsSupportLinks {
                Divider().overlay(Theme.Colors.border)

                supportAccessBar
                    .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.outerPadding - Theme.Spacing.s8)
                    .padding(.vertical, Theme.Spacing.s4)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.Colors.surface)
    }

    /// Support access: system check details, activity log, diagnostics export, and bug reports.
    private var supportAccessBar: some View {
        HStack(spacing: Theme.Spacing.s4) {
            Button {
                viewModel.isShowingSystemChecksSheet = true
            } label: {
                Label("System check details", systemImage: "checklist")
            }

            Button {
                viewModel.isShowingActivityLogSheet = true
            } label: {
                let count = viewModel.logEntries.count
                Label(count > 0 ? "Activity log (\(count))" : "Activity log", systemImage: "text.alignleft")
                    .monospacedDigit()
            }

            Button {
                viewModel.exportDiagnostics(appVersion: appVersion)
            } label: {
                Label("Export diagnostics…", systemImage: "square.and.arrow.up")
            }

            Button {
                viewModel.openBugReportSheet(appVersion: appVersion)
            } label: {
                Label("Report a bug…", systemImage: "ladybug")
            }
            .disabled(viewModel.isReportingBug)

            Spacer(minLength: 0)
        }
        .buttonStyle(QuietLinkButtonStyle(color: Theme.Colors.textSecondary))
    }

    private var footerStatusText: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Image(systemName: footerGuidance.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(footerGuidance.tone.color)
                .accessibilityHidden(true)

            Text(footerGuidance.message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func footerActionButtons(stage: WorkspaceStage, stacked: Bool = false) -> some View {
        let isRepairRetry = stage == .results && RunKind(record: viewModel.currentRunRecord) == .repair
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s8))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.s8))
        return layout {
            if viewModel.isRunning {
                Button(action: { viewModel.cancelWorkflow() }) {
                    Label(
                        viewModel.isCanceling
                            ? "Stopping…"
                            : (RunKind(record: viewModel.currentRunRecord) == .sandboxLaunch ? "Stop launch" : "Stop repair"),
                        systemImage: "stop.fill"
                    )
                }
                .buttonStyle(ThemedButtonStyle(variant: .destructive))
                .disabled(viewModel.isCanceling)
            } else {
                Button(action: { viewModel.dryRun() }) {
                    Label("Preview steps", systemImage: "eye")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .help("Read-only: inspects all 9 repair steps without modifying files, network state, or processes.")

                Button("Launch in sandbox", action: { viewModel.launchZoomOnly() })
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(!viewModel.canStartZoom)
                    .help("Closes existing Zoom and launches in the required sandbox. No reset or administrator operations. Starting normal Zoom separately bypasses this protection.")

                Button(action: { viewModel.prepareAndPresentRepairPlan() }) {
                    Label(
                        isRepairRetry ? "Review repair again…" : "Review repair…",
                        systemImage: isRepairRetry ? "arrow.clockwise" : "play.fill"
                    )
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .disabled(!viewModel.canStartZoom)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Action-area guidance: what the buttons will do, why they are unavailable, and
    /// safety notices. The run's outcome itself is narrated by the pinned summary.
    private var footerGuidance: (message: String, icon: String, tone: StatusTone) {
        if viewModel.hasUnsettledPrivilegedOperation {
            return (PrivilegedOperationGuard.recoveryMessage, "exclamationmark.octagon.fill", .error)
        }
        if viewModel.isCanceling {
            if viewModel.isExecutingPrivilegedStep {
                return (
                    "Waiting for the current administrator command to finish before stopping…",
                    "lock.shield.fill",
                    .warning
                )
            }
            return (
                "Finishing the active step safely before stopping…",
                "hand.raised.fill",
                .warning
            )
        }

        let runKind = RunKind(record: viewModel.currentRunRecord)

        if viewModel.workflowState.isActiveRun {
            switch runKind ?? .repair {
            case .preview:
                return (
                    "Read-only: no files, network state, or processes are modified.",
                    "eye",
                    .active
                )
            case .sandboxLaunch:
                return (
                    "Launching verified Zoom in the required sandbox without reset or administrator operations.",
                    "lock.shield",
                    .active
                )
            case .repair:
                return (
                    "Network and DNS work share one administrator prompt when supported; DNS may run before reset.",
                    "lock.shield",
                    .active
                )
            }
        }

        switch viewModel.workflowState {
        case .canceling:
            return ("Stopping repair safely…", "hand.raised.fill", .warning)
        case .completed where runKind == .sandboxLaunch:
            return (
                "Sandbox launch finished. Starting normal Zoom separately bypasses this protection.",
                "checkmark.shield",
                .success
            )
        default:
            break
        }

        if case .loading = viewModel.preflight.status {
            return ("Waiting for system checks to finish.", "hourglass", .neutral)
        }
        if !viewModel.canStartZoom {
            return (
                "Repair unavailable until the blocking system check is resolved. Preview steps still runs read-only.",
                "exclamationmark.octagon.fill",
                .error
            )
        }
        return (
            "Preview steps is read-only. Review repair… shows the exact plan before anything changes.",
            "shield.lefthalf.filled",
            .neutral
        )
    }

    private func configureWindowAndCaptureIfRequested() {
        guard AppConfiguration.allowsDebugEnvironmentOverrides else { return }
        let env = ProcessInfo.processInfo.environment
        let sizeRaw = env["FIXER_WINDOW_SIZE"]
        let screenshotPath = env["FIXER_SCREENSHOT_PATH"]
        guard sizeRaw != nil || screenshotPath != nil else { return }

        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                window.appearance = NSAppearance(named: .darkAqua)
                if let sizeRaw {
                    let parts = sizeRaw.lowercased().split(separator: "x")
                    if parts.count == 2,
                       let width = Double(parts[0]),
                       let height = Double(parts[1]) {
                        window.setContentSize(CGSize(width: width, height: height))
                    }
                }
            }
        }

        if let screenshotPath, !screenshotPath.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                guard let window = NSApplication.shared.windows.first(where: { $0.attachedSheet != nil || $0.isVisible }) ?? NSApplication.shared.windows.first,
                      let contentView = window.contentView else {
                    NSApplication.shared.terminate(nil)
                    return
                }

                contentView.layoutSubtreeIfNeeded()
                let bounds = contentView.bounds
                guard let baseRep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                    NSApplication.shared.terminate(nil)
                    return
                }
                contentView.cacheDisplay(in: bounds, to: baseRep)

                let finalImage = NSImage(size: bounds.size)
                finalImage.lockFocus()
                baseRep.draw(in: bounds)

                if let sheetWindow = window.attachedSheet,
                   let sheetView = sheetWindow.contentView {
                    sheetView.layoutSubtreeIfNeeded()
                    let sheetBounds = sheetView.bounds
                    if let sheetRep = sheetView.bitmapImageRepForCachingDisplay(in: sheetBounds) {
                        sheetView.cacheDisplay(in: sheetBounds, to: sheetRep)
                        NSColor.black.withAlphaComponent(0.45).setFill()
                        bounds.fill(using: .sourceOver)
                        let originX = max((bounds.width - sheetBounds.width) / 2, 0)
                        let originY = max((bounds.height - sheetBounds.height) / 2, 0)
                        let destRect = NSRect(
                            x: originX,
                            y: originY,
                            width: sheetBounds.width,
                            height: sheetBounds.height
                        )
                        sheetRep.draw(in: destRect)
                    }
                }

                finalImage.unlockFocus()

                if let tiffData = finalImage.tiffRepresentation,
                   let outRep = NSBitmapImageRep(data: tiffData),
                   let pngData = outRep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: URL(fileURLWithPath: screenshotPath), options: .atomic)
                }

                fflush(nil)
                _exit(0)
            }
        }
    }
}

