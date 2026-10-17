import SwiftUI

struct PreflightPanel: View {
    let preflight: AppViewModel.PreflightInfo

    private static let supportMatrix: [(label: String, supported: Bool)] = [
        ("Intel", true),
        ("Apple Silicon", true),
        ("macOS 13", true),
        ("macOS 14+", true),
        ("Wi-Fi", true),
        ("Ethernet", true),
        ("VPN", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label("Preflight Checks", systemImage: "checklist")
                .font(Theme.Typography.heading)
                .foregroundStyle(Theme.Colors.textPrimary)

            switch preflight.status {
            case .loading:
                HStack(spacing: Theme.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking system…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .error(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.error)
            case .ready:
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: Theme.Spacing.small
                ) {
                    ForEach(preflight.checks) { check in
                        PreflightCheckRow(check: check)
                    }
                }
            }

            Divider().overlay(Theme.Colors.border)

            ViewThatFits(in: .horizontal) {
                supportPills
                VStack(alignment: .leading, spacing: Theme.Spacing.small) { supportPills }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedPanel()
    }

    private var supportPills: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text("Supported")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.textSecondary)
            ForEach(Self.supportMatrix, id: \.label) { item in
                Text(item.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(item.supported ? Theme.Colors.success : Theme.Colors.error)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.xSmall)
                    .background((item.supported ? Theme.Colors.success : Theme.Colors.error).opacity(0.14))
                    .clipShape(Capsule())
                    .accessibilityLabel("\(item.label): \(item.supported ? "supported" : "not supported")")
            }
        }
    }
}

private struct PreflightCheckRow: View {
    let check: AppViewModel.PreflightInfo.Check

    private var status: (label: String, image: String, color: Color) {
        if check.isBlocking {
            return ("Blocked", "xmark.circle.fill", Theme.Colors.error)
        }
        if check.isWarning {
            return ("Warning", "exclamationmark.triangle.fill", Theme.Colors.warning)
        }
        return ("Passed", "checkmark.circle.fill", Theme.Colors.success)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Image(systemName: status.image)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            Text("\(check.label):")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(check.value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.label). \(check.label): \(check.value)")
    }
}
