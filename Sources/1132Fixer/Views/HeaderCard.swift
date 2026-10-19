import SwiftUI

struct HeaderCard: View {
    let appVersion: String
    let workflowState: AppViewModel.WorkflowState
    let canStartZoom: Bool
    let logCount: Int
    let isReportBugDisabled: Bool
    let onOpenActivityLog: () -> Void
    let onExportDiagnostics: () -> Void
    let onReportBug: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            compactHeader
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .themedLedger()
        .accessibilityElement(children: .contain)
    }

    private var wideHeader: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            identityCluster
            Spacer(minLength: Theme.Spacing.medium)
            statusBadge
            utilityActions
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                identityCluster
                Spacer(minLength: Theme.Spacing.small)
                statusBadge
            }

            HStack(spacing: Theme.Spacing.small) {
                Spacer()
                utilityActions
            }
        }
    }

    private var identityCluster: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.Colors.primary.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(Theme.Colors.primary.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text("1132 Fixer")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text("v\(appVersion)")
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Colors.textMuted)
                }

                Text("Zoom error 1132 repair & sandbox launcher")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: statusDescriptor.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusDescriptor.color)
                .accessibilityHidden(true)

            Text(statusDescriptor.label)
                .font(Theme.Typography.label)
                .foregroundStyle(statusDescriptor.color)
        }
        .padding(.horizontal, Theme.Spacing.small + 2)
        .padding(.vertical, 4)
        .background(statusDescriptor.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .stroke(statusDescriptor.color.opacity(0.32), lineWidth: 1)
        )
        .accessibilityLabel("Session status: \(statusDescriptor.label)")
    }

    private var utilityActions: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            Button(action: onOpenActivityLog) {
                HStack(spacing: 5) {
                    Image(systemName: "text.alignleft")
                    Text(logCount > 0 ? "Activity Log (\(logCount))" : "Activity Log")
                }
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))

            Button(action: onExportDiagnostics) {
                Label("Export Diagnostics…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))

            Button(action: onReportBug) {
                Label("Report Issue…", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))
            .disabled(isReportBugDisabled)
        }
    }

    private var statusDescriptor: (label: String, icon: String, color: Color) {
        switch workflowState {
        case .idle:
            if canStartZoom {
                return ("Ready to Repair", "checkmark.circle.fill", Theme.Colors.success)
            }
            return ("Action Blocked", "exclamationmark.octagon.fill", Theme.Colors.error)
        case .preflight,
            .closingZoom,
            .spoofingMAC,
            .checkingNetwork,
            .backingUpState,
            .clearingState,
            .flushingDNS,
            .stoppingUpdaters,
            .checkingMediaAccess,
            .launchingZoom:
            return (
                "Running…",
                "bolt.horizontal.circle.fill",
                Theme.Colors.primary
            )
        case .canceling:
            return ("Stopping…", "hand.raised.fill", Theme.Colors.warning)
        case .canceled:
            return ("Interrupted", "stop.circle.fill", Theme.Colors.warning)
        case .failed:
            return ("Stopped Safely", "xmark.circle.fill", Theme.Colors.error)
        case .completed:
            return ("Completed", "checkmark.circle.fill", Theme.Colors.success)
        }
    }
}
