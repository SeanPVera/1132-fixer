import SwiftUI

struct WorkflowProgressBar: View {
    let progress: AppViewModel.WorkflowProgress

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            ForEach(progress.steps) { step in
                VStack(spacing: Theme.Spacing.xSmall) {
                    stepIcon(step.state)
                        .font(.system(size: 12, weight: .semibold))
                    Text(step.name)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.name): \(stateLabel(step.state))")
            }
        }
        .padding(Theme.Spacing.medium)
        .themedPanel(radius: Theme.Radius.medium)
    }

    @ViewBuilder
    private func stepIcon(_ state: AppViewModel.WorkflowProgress.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Theme.Colors.textSecondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Colors.success)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Colors.warning)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.Colors.error)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(Theme.Colors.warning)
        }
    }

    private func stateLabel(_ state: AppViewModel.WorkflowProgress.StepState) -> String {
        switch state {
        case .pending: return "Pending"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .warning: return "Warning"
        case .failed: return "Needs attention"
        case .skipped: return "Skipped"
        }
    }
}
