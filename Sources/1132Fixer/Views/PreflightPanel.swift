import SwiftUI

struct PreflightPanel: View {
    let preflight: AppViewModel.PreflightInfo

    static let supportMatrix: [(label: String, supported: Bool)] = [
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
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedPanel()
    }
}

struct ReadinessSummaryLedger: View {
    let preflight: AppViewModel.PreflightInfo
    let isRunning: Bool
    let onInspectDetails: () -> Void
    let onRecheck: () -> Void

    private var blockingChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter(\.isBlocking)
    }

    private var warningChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter { $0.isWarning && !$0.isBlocking }
    }

    private var passedChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter { !$0.isBlocking && !$0.isWarning }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                statusHeader

                Spacer(minLength: Theme.Spacing.medium)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.small) {
                        compactCheckPills
                        actionButtons
                    }
                    actionButtons
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)

            if let primaryBlocker = blockingChecks.first {
                Divider().overlay(Theme.Colors.borderSubtle)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Theme.Colors.error)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Blocked by \(primaryBlocker.label):")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.error)
                    Text(primaryBlocker.value)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
                .background(Theme.Colors.error.opacity(0.08))
            } else if let primaryWarning = warningChecks.first {
                Divider().overlay(Theme.Colors.borderSubtle)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.warning)
                        .font(.system(size: 12, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("\(primaryWarning.label) Advisory:")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.warning)
                    Text(primaryWarning.value)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
                .background(Theme.Colors.warning.opacity(0.07))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedLedger()
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch preflight.status {
        case .loading:
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SYSTEM READINESS")
                        .font(Theme.Typography.sectionEyebrow)
                        .tracking(0.72)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text("Inspecting macOS, Zoom signature, network, backup capacity, and sandbox…")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        case .error(let message):
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.Colors.error)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SYSTEM READINESS")
                        .font(Theme.Typography.sectionEyebrow)
                        .tracking(0.72)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(message)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.error)
                }
            }
        case .ready:
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: readinessIcon)
                    .foregroundStyle(readinessColor)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SYSTEM READINESS")
                        .font(Theme.Typography.sectionEyebrow)
                        .tracking(0.72)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(readinessSummaryText)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
            }
        }
    }

    private var readinessIcon: String {
        if !blockingChecks.isEmpty { return "xmark.circle.fill" }
        if !warningChecks.isEmpty { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var readinessColor: Color {
        if !blockingChecks.isEmpty { return Theme.Colors.error }
        if !warningChecks.isEmpty { return Theme.Colors.warning }
        return Theme.Colors.success
    }

    private var readinessSummaryText: String {
        if !blockingChecks.isEmpty {
            let count = blockingChecks.count
            return "\(count) blocking \(count == 1 ? "issue" : "issues") · \(passedChecks.count)/\(preflight.checks.count) checks passed"
        }
        if !warningChecks.isEmpty {
            let count = warningChecks.count
            return "Ready with \(count) \(count == 1 ? "advisory" : "advisories") · \(passedChecks.count)/\(preflight.checks.count) checks passed"
        }
        return "All \(preflight.checks.count) preflight checks passed"
    }

    private var compactCheckPills: some View {
        HStack(spacing: Theme.Spacing.xxSmall) {
            ForEach(preflight.checks) { check in
                HStack(spacing: 4) {
                    Image(systemName: checkIcon(for: check))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(checkColor(for: check))
                        .accessibilityHidden(true)
                    Text(shortLabel(for: check.label))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 3)
                .background(Theme.Colors.surfaceRecessed)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(Theme.Colors.borderSubtle, lineWidth: 1)
                )
                .accessibilityLabel("\(check.label): \(checkStatusLabel(for: check)). \(check.value)")
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button(action: onRecheck) {
                Label("Recheck", systemImage: "arrow.clockwise")
            }
            .buttonStyle(QuietLinkButtonStyle())
            .disabled(isRunning)

            Button(action: onInspectDetails) {
                Label("Inspect Checks…", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(ThemedButtonStyle(variant: .secondary))
        }
    }

    private func shortLabel(for label: String) -> String {
        switch label {
        case "Architecture": return "Arch"
        case "Zoom App": return "Zoom"
        case "Backup Space": return "Space"
        case "Sandbox": return "Sandbox"
        default: return label
        }
    }

    private func checkIcon(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "xmark.circle.fill" }
        if check.isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func checkColor(for check: AppViewModel.PreflightInfo.Check) -> Color {
        if check.isBlocking { return Theme.Colors.error }
        if check.isWarning { return Theme.Colors.warning }
        return Theme.Colors.success
    }

    private func checkStatusLabel(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "Blocked" }
        if check.isWarning { return "Warning" }
        return "Passed"
    }
}

struct SystemCheckDetailsSheet: View {
    let preflight: AppViewModel.PreflightInfo
    let zoomAppPath: String
    let isRunning: Bool
    let onRecheck: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text("System Readiness & Compatibility")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Preflight verification for macOS, Zoom code signature, network state, backup capacity, and sandbox-exec.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Spacer()

                Button(action: onRecheck) {
                    Label("Re-run Checks", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .disabled(isRunning)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("PREFLIGHT CHECK LEDGER")
                    .font(Theme.Typography.sectionEyebrow)
                    .tracking(0.72)
                    .foregroundStyle(Theme.Colors.textMuted)

                VStack(spacing: 0) {
                    ForEach(Array(preflight.checks.enumerated()), id: \.element.id) { index, check in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                            HStack(spacing: Theme.Spacing.xSmall) {
                                Image(systemName: statusIcon(for: check))
                                    .foregroundStyle(statusColor(for: check))
                                    .accessibilityHidden(true)
                                Text(statusText(for: check))
                                    .font(Theme.Typography.label)
                                    .foregroundStyle(statusColor(for: check))
                            }
                            .frame(width: 96, alignment: .leading)

                            Text(check.label)
                                .font(Theme.Typography.stepTitle)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .frame(width: 120, alignment: .leading)

                            Text(check.value)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Theme.Spacing.medium)
                        .padding(.vertical, Theme.Spacing.small + 2)
                        .background(index.isMultiple(of: 2) ? Theme.Colors.surface : Theme.Colors.surfaceRecessed.opacity(0.45))

                        if index < preflight.checks.count - 1 {
                            Divider().overlay(Theme.Colors.borderSubtle)
                        }
                    }
                }
                .themedLedger()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("TARGET ZOOM BUNDLE")
                    .font(Theme.Typography.sectionEyebrow)
                    .tracking(0.72)
                    .foregroundStyle(Theme.Colors.textMuted)

                Text(zoomAppPath)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.surfaceRecessed)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("ENVIRONMENT SUPPORT MATRIX")
                    .font(Theme.Typography.sectionEyebrow)
                    .tracking(0.72)
                    .foregroundStyle(Theme.Colors.textMuted)

                HStack(spacing: Theme.Spacing.small) {
                    ForEach(PreflightPanel.supportMatrix, id: \.label) { item in
                        HStack(spacing: 4) {
                            Image(systemName: item.supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.supported ? Theme.Colors.success : Theme.Colors.error)
                                .accessibilityHidden(true)
                            Text(item.supported ? item.label : "\(item.label) (Unsupported)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(item.supported ? Theme.Colors.textPrimary : Theme.Colors.error)
                        }
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.xxSmall)
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                .stroke(Theme.Colors.border, lineWidth: 1)
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 460, alignment: .topLeading)
        .background(Theme.Colors.background)
        .preferredColorScheme(.dark)
    }

    private func statusIcon(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "xmark.circle.fill" }
        if check.isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func statusColor(for check: AppViewModel.PreflightInfo.Check) -> Color {
        if check.isBlocking { return Theme.Colors.error }
        if check.isWarning { return Theme.Colors.warning }
        return Theme.Colors.success
    }

    private func statusText(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "Blocked" }
        if check.isWarning { return "Advisory" }
        return "Passed"
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
