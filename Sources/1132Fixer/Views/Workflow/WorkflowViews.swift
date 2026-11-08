import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct WorkflowProgressBar: View {
    let progress: AppViewModel.WorkflowProgress

    var body: some View {
        HStack(alignment: .top, spacing: Design.s1) {
            ForEach(progress.steps) { step in
                VStack(spacing: Design.s1) {
                    stepIcon(step.state)
                        .font(.system(size: 14))
                        .frame(height: 16)
                    Text(step.name)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .panelChrome(padding: Design.s2, radius: 16)
    }

    @ViewBuilder
    private func stepIcon(_ state: AppViewModel.WorkflowProgress.StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(Design.tertiaryText)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.yellow)
        }
    }
}

struct WorkflowStatusPanel: View {
    let state: AppViewModel.WorkflowState
    let resetTimedOut: Bool
    let isRunning: Bool
    let onRetryReset: () -> Void

    private var status: (icon: String, title: String, detail: String, tint: Color)? {
        switch state {
        case .clearingState:
            return ("lock.shield", "Waiting for password", "Approve the macOS prompt to reset Zoom data and refresh the DNS cache. If you cannot see it, check behind this window.", .yellow)
        case .checkingMediaAccess:
            return ("video.badge.checkmark", "Checking camera and microphone", "Zoom will still launch if access is unavailable, but affected devices will not work.", Design.accent)
        case .launchingZoom:
            return ("video.fill", "Launching Zoom securely", "Zoom is starting in required sandbox mode.", Design.accent)
        case .dryRunCompleted:
            return ("checkmark.circle.fill", "Dry run completed", "No repair or Zoom launch was performed.", .green)
        case .completed:
            return ("checkmark.circle.fill", "Repair completed", "Zoom launch completed. Review any warning steps above.", .green)
        case .resetCompleted:
            return ("checkmark.circle.fill", "Zoom data reset", "Reset completed. Run Start Zoom when you are ready to continue.", .green)
        case .failed(let message):
            return ("exclamationmark.triangle.fill", resetTimedOut ? "Reset timed out" : "Repair stopped", resetTimedOut ? "The password prompt may be hidden. Check behind this window, then retry only the reset step." : message, .red)
        case .canceled:
            return ("xmark.circle.fill", "Repair canceled", "No more workflow steps will run.", .yellow)
        default:
            return nil
        }
    }

    var body: some View {
        if let status {
            HStack(spacing: Design.s2) {
                Image(systemName: status.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Design.primaryText)
                    Text(status.detail)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                }

                Spacer(minLength: Design.s2)

                if resetTimedOut {
                    Button("Try Reset Again", action: onRetryReset)
                        .secondaryControl(isProminent: true)
                        .buttonStyle(AppButtonStyle())
                        .disabled(isRunning)
                }
            }
            .panelChrome(padding: Design.s2, radius: 16)
        }
    }
}
