import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = AppConfiguration.repositoryURL
    private let websiteURL = AppConfiguration.websiteURL
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?
    @State private var showRepairConfirmation = false
    @State private var isReportingBug = false
    @State private var showBugReportForm = false
    @State private var bugReportEmail = ""
    @State private var bugReportMessage = ""
    @State private var bugReportError: String?

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.large) {
                    HeaderCard(
                        repositoryURL: repositoryURL,
                        websiteURL: websiteURL,
                        onReportBug: {
                            bugReportError = nil
                            showBugReportForm = true
                        },
                        isReportBugDisabled: isReportingBug,
                        onExportDiagnostics: { vm.exportDiagnostics(appVersion: appVersion) },
                        appVersion: appVersion
                    )

                    PreflightPanel(preflight: vm.preflight)

                    ZoomLocationPanel(
                        appPath: vm.zoomAppPath,
                        isCustom: vm.customZoomAppPath != nil,
                        isDisabled: vm.isRunning,
                        onChoose: { vm.chooseZoomLocation() },
                        onReset: { vm.resetZoomLocation() }
                    )

                    HStack(alignment: .top, spacing: Theme.Spacing.large) {
                        ActionCard(
                            title: "Start Zoom Repair",
                            subtitle: "Back up local state, refresh the active network and DNS, then launch verified Zoom in sandbox mode.",
                            systemImage: "wrench.and.screwdriver.fill",
                            tint: Theme.Colors.primary,
                            isDisabled: !vm.canStartZoom,
                            action: { showRepairConfirmation = true }
                        )

                        if vm.isRunning {
                            ActionCard(
                                title: vm.isCanceling ? "Canceling…" : "Cancel",
                                subtitle: vm.isCanceling
                                    ? "Finishing the current operation safely."
                                    : "Stop before the next workflow step begins.",
                                systemImage: "xmark.circle.fill",
                                tint: Theme.Colors.error,
                                isDisabled: vm.isCanceling,
                                action: { vm.cancelWorkflow() }
                            )
                        } else {
                            ActionCard(
                                title: "Dry Run",
                                subtitle: "Inspect compatibility, Zoom, network, backup space, and sandbox readiness without changing anything.",
                                systemImage: "eye.fill",
                                tint: Theme.Colors.textSecondary,
                                isDisabled: false,
                                action: { vm.dryRun() }
                            )
                        }
                    }

                    if let progress = vm.workflowProgress {
                        WorkflowProgressBar(progress: progress)
                    }

                    if let results = vm.lastRunResults {
                        WorkflowResultCard(
                            results: results,
                            workflowState: vm.workflowState,
                            latestBackupPath: vm.latestBackupPath,
                            onRevealBackup: vm.revealLatestBackup
                        )
                    }

                    LogPanel(logs: vm.logs, onCopy: vm.copyLogs, onClear: vm.clearLogs)
                }
                .padding(Theme.Spacing.xLarge)
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .preferredColorScheme(.dark)
        .onAppear { vm.runPreflight() }
        .task { await checkForUpdates() }
        .alert("Update Available", isPresented: $updateAlertIsPresented) {
            Button("View Release") {
                if let latestRelease {
                    NSWorkspace.shared.open(latestRelease.htmlURL)
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            if let release = latestRelease {
                if let notes = release.releaseNotes, !notes.isEmpty {
                    Text("Version \(release.version) is available. You have \(appVersion).\n\n\(notes)")
                } else {
                    Text("Version \(release.version) is available. You have \(appVersion).")
                }
            } else {
                Text("A newer version is available.")
            }
        }
        .sheet(isPresented: $showRepairConfirmation) {
            RepairConfirmationSheet(
                networkChangeDescription: "Change and reconnect the network identity when supported; otherwise verify the current connection without changing it.",
                onCancel: { showRepairConfirmation = false },
                onConfirm: {
                    showRepairConfirmation = false
                    vm.startZoom()
                }
            )
        }
        .sheet(isPresented: $showBugReportForm) {
            BugReportFormSheet(
                email: $bugReportEmail,
                message: $bugReportMessage,
                submissionError: $bugReportError,
                isSubmitting: isReportingBug,
                onCancel: { showBugReportForm = false },
                onSubmit: {
                    Task {
                        await reportBug(email: bugReportEmail, message: bugReportMessage)
                    }
                }
            )
        }
    }

    private func checkForUpdates() async {
        guard appVersion != "dev", latestRelease == nil else { return }

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

    @MainActor
    private func reportBug(email: String, message: String) async {
        guard !isReportingBug else { return }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            bugReportError = "Add a short description before sending the report."
            return
        }

        isReportingBug = true
        bugReportError = nil
        defer { isReportingBug = false }

        vm.logMessage("=== Report a Bug ===")
        let draft = await vm.makeBugReportDraft(appVersion: appVersion)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await BugReportService.sendBugReport(
                title: draft.title,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: trimmedMessage,
                systemInfo: draft.systemInfo,
                diagnosticsFileName: draft.diagnosticsFileName,
                diagnosticsData: draft.diagnosticsData
            )
            vm.logMessage("Bug report submitted successfully.")
            showBugReportForm = false
            bugReportEmail = ""
            bugReportMessage = ""
        } catch {
            let message = error.localizedDescription
            bugReportError = message
            vm.logMessage("Bug report failed: \(message)")
        }
    }
}
