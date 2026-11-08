import SwiftUI
import AppKit

/// Compact native identity: product name, version badge, update availability, and Help access.
struct HeaderCard: View {
    let appVersion: String
    let latestRelease: ReleaseInfo?

    private var versionText: String {
        appVersion.first?.isNumber == true ? "v\(appVersion)" : appVersion
    }

    /// The shipped AppIcon.png, so `swift run` shows the real mark instead of AppKit's
    /// generic executable icon; falls back to the bundle icon.
    private static let identityIcon: NSImage =
        PackagedResources.resourceURL(named: "AppIcon.png").flatMap(NSImage.init(contentsOf:))
            ?? NSApplication.shared.applicationIconImage

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s12) {
            Image(nsImage: Self.identityIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Theme.Identity.iconSize, height: Theme.Identity.iconSize)
                .accessibilityHidden(true)

            Text("1132 Fixer")
                .font(Theme.Typography.compactIdentity)
                .foregroundStyle(Theme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)

            StatusTag(text: versionText)
                .accessibilityLabel("Version \(appVersion)")

            if let latestRelease {
                Button {
                    NSWorkspace.shared.open(latestRelease.htmlURL)
                } label: {
                    Label("Update available: v\(latestRelease.version)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(QuietLinkButtonStyle())
                .help("Open the release page on GitHub")
            }

            Spacer(minLength: Theme.Spacing.s12)

            Menu {
                Button("1132 Fixer website") {
                    NSWorkspace.shared.open(AppConfiguration.websiteURL)
                }
                Button("GitHub repository") {
                    NSWorkspace.shared.open(AppConfiguration.repositoryURL)
                }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Website and source code")
        }
        .accessibilityElement(children: .contain)
    }
}
