import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.8.3"

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        GeometryReader { proxy in
            let availableContentWidth = min(
                max(proxy.size.width - (Theme.Spacing.outerPadding * 2), 0),
                Theme.Window.contentMaxWidth
            )
            let isCompactLedger = availableContentWidth < Theme.Window.wideLedgerBreakpoint

            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        HeaderCard(
                            appVersion: appVersion,
                            workflowState: viewModel.workflowState,
                            canStartZoom: viewModel.canStartZoom,
                            logCount: viewModel.logEntries.count,
                            isReportBugDisabled: viewModel.isReportingBug,
                            onOpenActivityLog: { viewModel.isShowingActivityLogSheet = true },
                            onExportDiagnostics: { viewModel.exportDiagnostics(appVersion: appVersion) },
                            onReportBug: {
                                viewModel.openBugReportSheet(appVersion: appVersion)
                            }
                        )

                        ReadinessSummaryLedger(
                            preflight: viewModel.preflight,
                            isRunning: viewModel.isRunning,
                            onInspectDetails: { viewModel.isShowingSystemChecksSheet = true },
                            onRecheck: { viewModel.runPreflight() }
                        )

                        ZoomLocationPanel(
                            appPath: viewModel.zoomAppPath,
                            isCustom: viewModel.customZoomAppPath != nil,
                            isDisabled: viewModel.isRunning,
                            installationNotice: viewModel.installationNotice,
                            onChoose: { viewModel.chooseZoomLocation() },
                            onReset: { viewModel.resetZoomLocation() },
                            onDismissNotice: { viewModel.installationNotice = nil }
                        )

                        RepairRecordLedgerView(
                            steps: viewModel.workflowProgress?.steps ?? [],
                            stepResults: viewModel.lastRunResults ?? [],
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
                    .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.outerPadding)
                    .padding(.top, Theme.Spacing.outerPadding)
                    .padding(.bottom, Theme.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomActionBar
                }
            }
        }
        .frame(
            minWidth: Theme.Window.minWidth,
            idealWidth: Theme.Window.idealWidth,
            minHeight: Theme.Window.minHeight,
            idealHeight: Theme.Window.idealHeight
        )
        .preferredColorScheme(.dark)
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

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.Colors.border)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Spacing.large) {
                    footerStatusText
                    Spacer(minLength: Theme.Spacing.medium)
                    footerActionButtons
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    footerStatusText
                    HStack {
                        Spacer()
                        footerActionButtons
                    }
                }
            }
            .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.outerPadding)
            .padding(.vertical, Theme.Spacing.medium)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.surface)
        }
    }

    private var footerStatusText: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: footerGuidance.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(footerGuidance.color)
                .accessibilityHidden(true)

            Text(footerGuidance.message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
        }
    }

    private var footerActionButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            if viewModel.isRunning {
                Button(action: { viewModel.cancelWorkflow() }) {
                    Label(
                        viewModel.isCanceling ? "Stopping…" : "Stop Repair",
                        systemImage: "stop.fill"
                    )
                }
                .buttonStyle(ThemedButtonStyle(variant: .destructive))
                .disabled(viewModel.isCanceling)
            } else {
                Button(action: { viewModel.dryRun() }) {
                    Label("Preview Steps", systemImage: "eye")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))

                Button(action: { viewModel.prepareAndPresentRepairPlan() }) {
                    Label("Review & Run Repair…", systemImage: "play.fill")
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .disabled(!viewModel.canStartZoom)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footerGuidance: (message: String, icon: String, color: Color) {
        if viewModel.isCanceling {
            if viewModel.isExecutingPrivilegedStep {
                return (
                    "Waiting for the current administrator command to finish before stopping…",
                    "lock.shield.fill",
                    Theme.Colors.warning
                )
            }
            return (
                "Finishing the active step safely before stopping…",
                "hand.raised.fill",
                Theme.Colors.warning
            )
        }

        switch viewModel.workflowState {
        case .preflight,
            .closingZoom,
            .spoofingMAC,
            .checkingNetwork,
            .backingUpState,
            .clearingState,
            .flushingDNS,
            .stoppingUpdaters,
            .checkingMediaAccess,
            .launchingZoom:
            let isPreview = viewModel.currentRunRecord?.title.localizedCaseInsensitiveContains("dry run") == true
                || viewModel.currentRunRecord?.title.localizedCaseInsensitiveContains("preview") == true
            return (
                isPreview
                    ? "Inspecting all 9 repair steps without modifying files, network state, or processes."
                    : "Executing repair sequence. Steps 04 & 06 prompt for macOS administrator privileges.",
                "bolt.horizontal.circle.fill",
                Theme.Colors.primary
            )
        case .canceling:
            return (
                "Stopping repair safely…",
                "hand.raised.fill",
                Theme.Colors.warning
            )
        case .canceled:
            return (
                "Run stopped before completion. Unrun steps remain marked Not started.",
                "stop.circle.fill",
                Theme.Colors.warning
            )
        case .failed(let reason):
            return (
                "Stopped safely: \(reason)",
                "xmark.circle.fill",
                Theme.Colors.error
            )
        case .completed:
            return (
                "Sequence finished. You can inspect the activity log, export diagnostics, or run again.",
                "checkmark.circle.fill",
                Theme.Colors.success
            )
        case .idle:
            if !viewModel.canStartZoom {
                return (
                    "Resolve the blocking preflight check above or run Preview Steps to inspect.",
                    "exclamationmark.octagon.fill",
                    Theme.Colors.error
                )
            }
            return (
                "Preview Steps runs a read-only check; Review & Run Repair shows the exact plan before changing anything.",
                "shield.lefthalf.filled",
                Theme.Colors.textSecondary
            )
        }
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

