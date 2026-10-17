import SwiftUI

struct ZoomLocationPanel: View {
    let appPath: String
    let isCustom: Bool
    let isDisabled: Bool
    let onChoose: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Label("Zoom Location", systemImage: "folder")
                    .font(Theme.Typography.subheading)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Spacer()
                if isCustom {
                    Text("Custom")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.warning)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.xSmall)
                        .background(Theme.Colors.warning.opacity(0.2))
                        .clipShape(Capsule())
                        .accessibilityLabel("Using a custom Zoom location")
                }
            }

            Text(appPath)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Zoom application path: \(appPath)")

            HStack(spacing: Theme.Spacing.small) {
                Button(action: onChoose) {
                    Label("Choose Location…", systemImage: "folder")
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .disabled(isDisabled)

                if isCustom {
                    Button(action: onReset) {
                        Text("Use Default")
                    }
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(isDisabled)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedPanel()
    }
}
