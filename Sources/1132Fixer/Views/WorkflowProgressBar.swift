import SwiftUI

struct WorkflowProgressBar: View {
    let progress: AppViewModel.WorkflowProgress

    var body: some View {
        HStack(spacing: 4) {
            ForEach(progress.steps) { step in
                VStack(spacing: 3) {
                    stepIcon(step.state)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text(step.name)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .terminalPanel()
    }

    @ViewBuilder
    private func stepIcon(_ state: AppViewModel.WorkflowProgress.StepState) -> some View {
        switch state {
        case .pending:
            Text("[ ]")
                .foregroundStyle(Theme.Colors.textMuted.opacity(0.5))
        case .running:
            Text("[~]")
                .foregroundStyle(Theme.Colors.accent)
        case .succeeded:
            Text("[X]")
                .foregroundStyle(Theme.Colors.success)
        case .failed:
            Text("[!]")
                .foregroundStyle(Theme.Colors.error)
        case .skipped:
            Text("[-]")
                .foregroundStyle(Theme.Colors.warning)
        }
    }
}
