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
        VStack(alignment: .leading, spacing: Theme.Spacing.s12) {
            Text("Zoom installation")
                .font(Theme.Typography.sectionHeading)
                .foregroundStyle(Theme.Signal.textPrimary)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    horizontalBar
                    stackedBar
                }
                .padding(.horizontal, Theme.Spacing.s16)
                .padding(.vertical, Theme.Spacing.s12)
                .frame(minHeight: Theme.Window.rowMinHeight)

                if let notice = installationNotice, !notice.isEmpty {
                    Divider().overlay(Theme.Signal.border)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Signal.warning)
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                        Text("Selection rejected:")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Signal.warning)
                        Text(notice)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Signal.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let onDismissNotice {
                            Button("Dismiss", action: onDismissNotice)
                                .buttonStyle(QuietLinkButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.s16)
                    .padding(.vertical, Theme.Spacing.s12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerContainer()
        }
    }

    private var pathText: some View {
        Text(appPath)
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Signal.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(appPath)
            .accessibilityLabel("Zoom application path: \(appPath)")
    }

    private var horizontalBar: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s12) {
            locationTag
            pathText
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButtons
        }
    }

    private var stackedBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
            HStack(alignment: .center, spacing: Theme.Spacing.s12) {
                locationTag
                Spacer(minLength: Theme.Spacing.s8)
                actionButtons
            }
            pathText
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var locationTag: some View {
        StatusTag(
            text: isCustom ? "Custom location" : "Default location",
            tone: isCustom ? .warning : .neutral
        )
    }

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.s8) {
            if isCustom {
                Button("Use default", action: onReset)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(isDisabled)
            }

            Button(action: onChoose) {
                Label("Choose…", systemImage: "folder")
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))
            .disabled(isDisabled)
            .help("Choose zoom.us.app if it is installed outside /Applications")
        }
    }
}
