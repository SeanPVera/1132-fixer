import SwiftUI

struct HeaderCard: View {
    let repositoryURL: URL
    let websiteURL: URL
    let onReportBug: () -> Void
    let isReportBugDisabled: Bool
    let onExportDiagnostics: () -> Void
    let appVersion: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Rectangle()
                    .fill(Theme.Colors.panelBackground)
                    .border(Theme.Colors.border, width: 1)
                    .frame(width: 58, height: 58)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.Colors.accent)
            }

            Text("1132 Fixer")
                .font(.system(size: 29, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.Colors.accent)

            Spacer()

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    HeaderLinkButton(title: "GitHub", systemImage: "link.circle.fill", destination: repositoryURL)
                        .frame(maxWidth: .infinity)
                    HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    HeaderActionButton(
                        title: "Report a bug",
                        systemImage: "ladybug.fill",
                        isDisabled: isReportBugDisabled,
                        action: onReportBug
                    )
                    .frame(maxWidth: .infinity)
                    HeaderActionButton(
                        title: "Export Diagnostics",
                        systemImage: "square.and.arrow.up",
                        isDisabled: false,
                        action: onExportDiagnostics
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 280)
        }
        .padding(18)
        .terminalPanel()
    }
}


struct HeaderLinkButton: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .modifier(HeaderButtonChrome())
    }
}


struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.58 : 1.0)
        .modifier(HeaderButtonChrome())
    }
}


struct HeaderButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Colors.accent)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .terminalPanel()
    }
}
