import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var zoomIsInstalled = ZoomLocation.isInstalled
    private let appVersion = AppConfiguration.appVersion

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    /// The shipped AppIcon.png, so `swift run` shows the real mark instead of AppKit's
    /// generic executable icon; falls back to the bundle icon.
    private static let identityIcon: NSImage =
        PackagedResources.resourceURL(named: "AppIcon.png").flatMap(NSImage.init(contentsOf:))
            ?? NSApplication.shared.applicationIconImage

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.majorSection) {
            header

            VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                Text(headline)
                    .font(Theme.Typography.statusHeadline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                statusLine
            }

            actions

            if !viewModel.log.isEmpty {
                logPanel
            } else {
                notes
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: Theme.Window.contentMaxWidth, alignment: .leading)
        .padding(Theme.Spacing.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.background)
        .frame(
            minWidth: Theme.Window.minWidth,
            idealWidth: Theme.Window.idealWidth,
            minHeight: Theme.Window.minHeight,
            idealHeight: Theme.Window.idealHeight
        )
        .preferredColorScheme(.dark)
        .tint(Theme.Colors.primary)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            zoomIsInstalled = ZoomLocation.isInstalled
        }
        .alert("Wipe Zoom's local data?", isPresented: $viewModel.isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset & Launch", role: .destructive) { viewModel.resetAndLaunchZoom() }
        } message: {
            Text("Zoom will be closed and its local data, settings, caches and logs will be deleted. You will need to sign in to Zoom again. This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s12) {
            Image(nsImage: Self.identityIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Theme.Identity.iconSize, height: Theme.Identity.iconSize)
                .accessibilityHidden(true)

            Text("1132 Fixer")
                .font(Theme.Typography.compactIdentity)
                .foregroundStyle(Theme.Colors.textPrimary)

            StatusTag(text: appVersion.first?.isNumber == true ? "v\(appVersion)" : appVersion)
                .accessibilityLabel("Version \(appVersion)")

            Spacer(minLength: Theme.Spacing.s12)

            Menu {
                Button("1132 Fixer website") { NSWorkspace.shared.open(AppConfiguration.websiteURL) }
                Button("GitHub repository") { NSWorkspace.shared.open(AppConfiguration.repositoryURL) }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.s8) {
            if viewModel.isRunning {
                Button(action: { viewModel.cancel() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(ThemedButtonStyle(variant: .destructive))
            } else {
                Button(action: { viewModel.isConfirmingReset = true }) {
                    Label("Reset & Launch…", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!zoomIsInstalled)
                .help("Closes Zoom, wipes its local data, then launches it in the sandbox.")

                Button("Launch Zoom", action: { viewModel.launchZoom() })
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(!zoomIsInstalled)
                    .help("Closes Zoom and relaunches it in the sandbox. Nothing is deleted.")
            }
            Spacer(minLength: 0)
        }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Image(systemName: statusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusTone.color)
                .accessibilityHidden(true)
            Text(statusMessage)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                    ForEach(Array(viewModel.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .terminalFont(size: 12)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .textSelection(.enabled)
                .padding(Theme.Spacing.s12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .themedPanel(background: Theme.Colors.surfaceRecessed)
            .onChange(of: viewModel.log.count) { count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .accessibilityLabel("Activity log")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
            Text("Always open Zoom from here. Starting Zoom any other way runs it outside the sandbox.")
            Text("The sandbox may not hide your network hardware address from Zoom. On macOS 15 or later, set Private Wi-Fi Address to Rotating in System Settings > Wi-Fi > Details.")
        }
        .font(Theme.Typography.metadata)
        .foregroundStyle(Theme.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Status text

    private var headline: String {
        switch viewModel.status {
        case .idle: return zoomIsInstalled ? "Ready" : "Zoom not found"
        case .running: return "Working…"
        case .succeeded: return "Done"
        case .failed: return "Didn't finish"
        }
    }

    private var statusMessage: String {
        switch viewModel.status {
        case .idle:
            return zoomIsInstalled
                ? "Launch Zoom runs it in the sandbox. Reset & Launch also wipes Zoom's local data first."
                : "Install Zoom in /Applications or ~/Applications from zoom.us/download, then come back."
        case .running(let message), .succeeded(let message), .failed(let message):
            return message
        }
    }

    private var statusTone: StatusTone {
        switch viewModel.status {
        case .idle: return zoomIsInstalled ? .neutral : .error
        case .running: return .active
        case .succeeded: return .success
        case .failed: return .error
        }
    }

    private var statusIcon: String {
        switch viewModel.status {
        case .idle: return zoomIsInstalled ? "lock.shield" : "exclamationmark.octagon.fill"
        case .running: return "hourglass"
        case .succeeded: return "checkmark.shield"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }
}
