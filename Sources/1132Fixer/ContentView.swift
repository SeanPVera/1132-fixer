import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = AppViewModel()
    private let repositoryURL = URL(string: "https://github.com/1132-Fixer/macos")!
    private let websiteURL = URL(string: "https://1132-fixer.xyz")!
    private let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

    @State private var updateAlertIsPresented = false
    @State private var latestRelease: ReleaseInfo?
    @State private var isReportingBug = false
    @State private var showBugReportForm = false
    @State private var showStartConfirmation = false
    @State private var showActiveReportWarning = false
    @State private var reportCapturedDuringWorkflow = false
    @State private var bugReportEmail = ""
    @State private var bugReportMessage = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.13),
                    Color(red: 0.05, green: 0.10, blue: 0.18),
                    Color(red: 0.06, green: 0.13, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: Design.s3) {
                Text("1132 Fixer")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Design.primaryText)

                HeaderCard(
                    repositoryURL: repositoryURL,
                    websiteURL: websiteURL,
                    onReportBug: {
                        if vm.isRunning {
                            showActiveReportWarning = true
                        } else {
                            reportCapturedDuringWorkflow = false
                            showBugReportForm = true
                        }
                    },
                    isReportBugDisabled: isReportingBug,
                    onExportDiagnostics: { vm.exportDiagnostics(appVersion: appVersion) }
                )

                PreflightPanel(
                    preflight: vm.preflight,
                    onOpenCameraSettings: { vm.openPrivacySettings(for: .video) },
                    onOpenMicrophoneSettings: { vm.openPrivacySettings(for: .audio) }
                )

                ZoomLocationPanel(
                    appPath: vm.zoomAppPath,
                    isCustom: vm.customZoomAppPath != nil,
                    isInstalled: vm.isZoomInstalled,
                    isDisabled: vm.isRunning,
                    onChoose: { vm.chooseZoomLocation() },
                    onReset: { vm.resetZoomLocation() },
                    onDownload: { vm.openZoomDownload() }
                )

                HStack(spacing: Design.s2) {
                    ActionCard(
                        title: vm.isZoomInstalled ? "Start Zoom" : "Zoom Required",
                        subtitle: vm.isZoomInstalled
                            ? "Checks the network, resets Zoom data, refreshes DNS, and launches Zoom in sandbox mode."
                            : "Install Zoom or choose its location before starting.",
                        systemImage: "video.circle.fill",
                        tint: Design.accent,
                        isPrimary: true,
                        isDisabled: vm.isRunning || !vm.isZoomInstalled,
                        action: {
                            showStartConfirmation = true
                        }
                    )

                    if vm.isRunning {
                        ActionCard(
                            title: "Cancel",
                            subtitle: "Stop the running workflow.",
                            systemImage: "xmark.circle.fill",
                            tint: Color.red.opacity(0.85),
                            isPrimary: false,
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
                            systemImage: "eye.circle.fill",
                            tint: Design.neutralAccent,
                            isPrimary: false,
                            isDisabled: vm.isRunning,
                            action: {
                                vm.dryRun()
                            }
                        )
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let progress = vm.workflowProgress {
                    WorkflowProgressBar(progress: progress)
                }

                WorkflowStatusPanel(
                    state: vm.workflowState,
                    resetTimedOut: vm.resetTimedOut,
                    isRunning: vm.isRunning,
                    onRetryReset: { vm.retryResetZoomData() }
                )

                LogPanel(logs: vm.logs, onCopy: vm.copyLogs, onClear: vm.clearLogs)
            }
            .padding(Design.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 640)
        .onAppear { vm.runPreflight() }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            vm.runPreflight()
        }
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
        .confirmationDialog(
            "Administrator authorization",
            isPresented: $showStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue") { vm.startZoom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS may ask once for your password to reset Zoom data and refresh the DNS cache; network repair can require additional administrator prompts on systems where MAC changes are enabled. Your password is handled by macOS and is never stored by 1132 Fixer.")
        }
        .confirmationDialog(
            "Repair still running",
            isPresented: $showActiveReportWarning,
            titleVisibility: .visible
        ) {
            Button("Wait", role: .cancel) {}
            Button("Report Current State") {
                reportCapturedDuringWorkflow = true
                showBugReportForm = true
            }
        } message: {
            Text("Wait for the repair to finish for more useful diagnostics. A report sent now will be marked as captured during an active workflow.")
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
        let userMessage = trimmedMessage.isEmpty ? "No user message provided." : trimmedMessage
        let reportMessage = reportCapturedDuringWorkflow
            ? "Captured during active workflow.\n\n\(userMessage)"
            : userMessage

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
            reportCapturedDuringWorkflow = false
        } catch {
            vm.logMessage("Bug report failed: \(error.localizedDescription)")
        }
    }
}
