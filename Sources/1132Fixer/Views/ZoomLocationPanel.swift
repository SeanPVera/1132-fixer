import SwiftUI

struct ZoomLocationPanel: View {
    let appPath: String
    let isCustom: Bool
    let isDisabled: Bool
    var installationNotice: String? = nil
    let onChoose: () -> Void
    let onReset: () -> Void
    var onDismissNotice: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                horizontalBar
                stackedBar
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)

            if let notice = installationNotice, !notice.isEmpty {
                Divider().overlay(Theme.Colors.borderSubtle)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(notice)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onDismissNotice {
                        Button("Dismiss", action: onDismissNotice)
                            .buttonStyle(QuietLinkButtonStyle())
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
                .background(Theme.Colors.warning.opacity(0.07))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedLedger()
    }

    private var horizontalBar: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            titleAndBadge

            Text(appPath)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Zoom application path: \(appPath)")

            actionButtons
        }
    }

    private var stackedBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                titleAndBadge
                Spacer()
                actionButtons
            }

            Text(appPath)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Zoom application path: \(appPath)")
        }
    }

    private var titleAndBadge: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityHidden(true)

            Text("Zoom App")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(isCustom ? "Custom Location" : "Default")
                .font(Theme.Typography.caption)
                .foregroundStyle(isCustom ? Theme.Colors.warning : Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 2)
                .background(isCustom ? Theme.Colors.warning.opacity(0.16) : Theme.Colors.surfaceRecessed)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(isCustom ? Theme.Colors.warning.opacity(0.45) : Theme.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            if isCustom {
                Button(action: onReset) {
                    Text("Use Default")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .disabled(isDisabled)
            }

            Button(action: onChoose) {
                Label("Choose Zoom.app…", systemImage: "folder")
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))
            .disabled(isDisabled)
        }
    }
}
