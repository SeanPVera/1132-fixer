import SwiftUI

struct WorkflowResultCard: View {
    let results: [AppViewModel.StepResult]
    let workflowState: AppViewModel.WorkflowState
    let latestBackupPath: String?
    let onRevealBackup: () -> Void

    private var headline: String {
        if workflowState == .canceled || workflowState == .canceling {
            return "Repair canceled safely"
        }
        if isFailedState || results.contains(where: { $0.outcome == .failed }) {
            return "Repair stopped safely"
        }
        if results.contains(where: { $0.outcome != .success }) {
            return "Repair completed with notes"
        }
        return "Repair completed"
    }

    private var headlineColor: Color {
        if workflowState == .canceled || workflowState == .canceling { return Theme.Colors.warning }
        if isFailedState || results.contains(where: { $0.outcome == .failed }) { return Theme.Colors.error }
        if results.contains(where: { $0.outcome != .success }) { return Theme.Colors.warning }
        return Theme.Colors.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                Label(headline, systemImage: headlineIcon)
                    .font(Theme.Typography.heading)
                    .foregroundStyle(headlineColor)
                Spacer()
                if latestBackupPath != nil {
                    Button(action: onRevealBackup) {
                        Label("Reveal Backup", systemImage: "folder")
                    }
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                }
            }

            ForEach(results) { result in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: icon(for: result.outcome))
                        .foregroundStyle(color(for: result.outcome))
                        .accessibilityHidden(true)
                    Text(result.outcome.label)
                        .font(Theme.Typography.label)
                        .foregroundStyle(color(for: result.outcome))
                        .frame(width: Theme.Spacing.section, alignment: .leading)
                    Text(result.name)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if let detail = result.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(result.outcome.accessibilityLabel): \(result.name). \(result.detail ?? "")")
            }

            if let latestBackupPath {
                Text("Recovery backup: \(latestBackupPath)")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedPanel()
    }

    private var headlineIcon: String {
        if workflowState == .canceled || workflowState == .canceling { return "stop.circle.fill" }
        if isFailedState || results.contains(where: { $0.outcome == .failed }) { return "xmark.circle.fill" }
        if results.contains(where: { $0.outcome != .success }) { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func icon(for outcome: AppViewModel.StepResult.Outcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for outcome: AppViewModel.StepResult.Outcome) -> Color {
        switch outcome {
        case .success: return Theme.Colors.success
        case .warning, .skipped: return Theme.Colors.warning
        case .failed: return Theme.Colors.error
        }
    }

    private var isFailedState: Bool {
        if case .failed = workflowState { return true }
        return false
    }
}
