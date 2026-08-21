import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/PrimeUpYourLife/1132-fixer")!
    private let websiteURL = URL(string: "https://1132-fixer.xyz")!
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?
    @State private var isReportingBug = false
    @State private var showBugReportForm = false
    @State private var bugReportEmail = ""
    @State private var bugReportMessage = ""

    var body: some View {
        ZStack {
            Theme.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HeaderCard(
                    repositoryURL: repositoryURL,
                    websiteURL: websiteURL,
                    onReportBug: { showBugReportForm = true },
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

                HStack(spacing: 14) {
                    ActionCard(
                        title: "Start Zoom",
                        subtitle: "Checks the active network, resets Zoom data, refreshes DNS cache, and launches Zoom in sandbox mode.",
                        systemImage: "terminal.fill",
                        tint: Theme.Colors.accent,
                        isDisabled: vm.isRunning,
                        action: {
                            vm.startZoom()
                        }
                    )

                    if vm.isRunning {
                        ActionCard(
                            title: "Cancel",
                            subtitle: "Stop the running workflow.",
                            systemImage: "xmark.square.fill",
                            tint: Theme.Colors.error,
                            isDisabled: false,
                            action: {
                                vm.cancelWorkflow()
                            }
                        )
                        .transition(.opacity)
                    } else {
                        ActionCard(
                            title: "Dry Run",
                            subtitle: "Check system state without making any changes.",
                            systemImage: "eye.square.fill",
                            tint: Theme.Colors.textMuted,
                            isDisabled: vm.isRunning,
                            action: {
                                vm.dryRun()
                            }
                        )
                    }
                }

                if let progress = vm.workflowProgress {
                    WorkflowProgressBar(progress: progress)
                }

                LogPanel(logs: vm.logs, onCopy: vm.copyLogs, onClear: vm.clearLogs)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { vm.runPreflight() }
        .task {
            // Only check for updates in packaged apps that have a real version.
            guard appVersion != "dev" else { return }
            guard latestRelease == nil else { return }

            do {
                let release = try await UpdateChecker.fetchLatestRelease()
                if UpdateChecker.isUpdateAvailable(currentVersion: appVersion, latestVersion: release.version) {
                    latestRelease = release
                    updateAlertIsPresented = true
                }
            } catch {
                // Silent failure: update checks should never block app usage.
            }
        }
        .alert("Update Available", isPresented: $updateAlertIsPresented) {
            Button("Download Update") {
                NSWorkspace.shared.open(websiteURL)
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
        .sheet(isPresented: $showBugReportForm) {
            BugReportFormSheet(
                email: $bugReportEmail,
                message: $bugReportMessage,
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

    @MainActor
    private func reportBug(email: String, message: String) async {
        guard !isReportingBug else { return }
        isReportingBug = true
        defer { isReportingBug = false }

        vm.logMessage("=== Report a Bug ===")
        let draft = vm.makeBugReportDraft(appVersion: appVersion)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportMessage = trimmedMessage.isEmpty ? "No user message provided." : trimmedMessage

        do {
            try await BugReportService.sendBugReport(
                title: draft.title,
                email: trimmedEmail.isEmpty ? nil : trimmedEmail,
                message: reportMessage,
                systemInfo: draft.systemInfo,
                diagnosticsFileName: draft.diagnosticsFileName,
                diagnosticsData: draft.diagnosticsData
            )
            vm.logMessage("Bug report submitted successfully.")
            showBugReportForm = false
            bugReportEmail = ""
            bugReportMessage = ""
        } catch {
            vm.logMessage("Bug report failed: \(error.localizedDescription)")
        }
    }
}










