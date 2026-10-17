import SwiftUI

struct HeaderCard: View {
    let repositoryURL: URL
    let websiteURL: URL
    let onReportBug: () -> Void
    let isReportBugDisabled: Bool
    let onExportDiagnostics: () -> Void
    let appVersion: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.large) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.primary.opacity(0.16))
                    .frame(
                        width: Theme.Spacing.section + Theme.Spacing.small,
                        height: Theme.Spacing.section + Theme.Spacing.small
                    )
                Image(systemName: "video.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.Colors.primary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text("1132 Fixer")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Zoom diagnostic & repair · v\(appVersion)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer(minLength: Theme.Spacing.xLarge)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.small) {
                    HeaderLinkButton(title: "GitHub", systemImage: "link", destination: repositoryURL)
                    HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
                    HeaderActionButton(
                        title: "Report a bug",
                        systemImage: "ladybug",
                        isDisabled: isReportBugDisabled,
                        action: onReportBug
                    )
                    HeaderActionButton(
                        title: "Export Diagnostics",
                        systemImage: "square.and.arrow.up",
                        isDisabled: false,
                        action: onExportDiagnostics
                    )
                }
                VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                    HStack(spacing: Theme.Spacing.small) {
                        HeaderLinkButton(title: "GitHub", systemImage: "link", destination: repositoryURL)
                        HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
                    }
                    HStack(spacing: Theme.Spacing.small) {
                        HeaderActionButton(
                            title: "Report a bug",
                            systemImage: "ladybug",
                            isDisabled: isReportBugDisabled,
                            action: onReportBug
                        )
                        HeaderActionButton(
                            title: "Export Diagnostics",
                            systemImage: "square.and.arrow.up",
                            isDisabled: false,
                            action: onExportDiagnostics
                        )
                    }
                }
            }
        }
        .padding(Theme.Spacing.large)
        .themedPanel()
        .accessibilityElement(children: .contain)
    }
}

private struct HeaderLinkButton: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ThemedButtonStyle(variant: .secondary))
        .accessibilityHint("Opens in your default browser")
    }
}

private struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ThemedButtonStyle(variant: .secondary))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}
