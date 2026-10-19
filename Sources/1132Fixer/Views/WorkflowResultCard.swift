import SwiftUI

struct WorkflowResultCard: View {
    let results: [AppViewModel.StepResult]
    let workflowState: AppViewModel.WorkflowState
    let latestBackupPath: String?
    let onRevealBackup: () -> Void

    private var headline: String {
        if workflowState == .canceled || workflowState == .canceling {
            return "Stopped before completion"
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
                        .frame(width: Theme.Spacing.section * 2.5, alignment: .leading)
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
        case .interrupted: return "stop.circle.fill"
        case .unstarted: return "circle"
        case .running: return "clock.fill"
        }
    }

    private func color(for outcome: AppViewModel.StepResult.Outcome) -> Color {
        switch outcome {
        case .success: return Theme.Colors.success
        case .warning, .skipped, .interrupted: return Theme.Colors.warning
        case .failed: return Theme.Colors.error
        case .unstarted: return Theme.Colors.textMuted
        case .running: return Theme.Colors.primary
        }
    }

    private var isFailedState: Bool {
        if case .failed = workflowState { return true }
        return false
    }
}

struct RepairRecordLedgerView: View {
    struct LedgerStepItem: Identifiable {
        let spec: RepairStepSpec
        let state: AppViewModel.WorkflowProgress.StepState
        let detail: String?

        var id: String { spec.id }
        var index: Int { spec.index }
        var name: String { spec.name }
        var scope: String { spec.scope }
        var summary: String { spec.plannedSummary }
        var commandSummary: String { spec.commandSummary }
        var requiresAdmin: Bool { spec.requiresAdmin }
    }

    let steps: [AppViewModel.WorkflowProgress.Step]
    var stepResults: [AppViewModel.StepResult] = []
    let workflowState: AppViewModel.WorkflowState
    let runRecord: RunRecord?
    var expandedStepIDs: Set<String> = []
    var onToggleExpand: ((String) -> Void)? = nil
    let isCompactLayout: Bool

    private var effectiveResults: [AppViewModel.StepResult] {
        if let recordSteps = runRecord?.steps, !recordSteps.isEmpty {
            return recordSteps
        }
        return stepResults
    }

    private var isPreviewRun: Bool {
        guard let title = runRecord?.title else { return false }
        return title.localizedCaseInsensitiveContains("dry run") || title.localizedCaseInsensitiveContains("preview")
    }

    private var ledgerSteps: [LedgerStepItem] {
        let canonical = RepairStepSpec.canonicalSteps()
        let resultsByID = Dictionary(uniqueKeysWithValues: effectiveResults.map { ($0.id, $0) })
        let progressByID = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.state) })

        return canonical.map { spec in
            let result = resultsByID[spec.id]
            let resolvedState: AppViewModel.WorkflowProgress.StepState
            if let progressState = progressByID[spec.id] {
                resolvedState = progressState
            } else if let outcome = result?.outcome {
                switch outcome {
                case .success: resolvedState = .succeeded
                case .warning: resolvedState = .warning
                case .skipped: resolvedState = .skipped
                case .failed: resolvedState = .failed
                case .interrupted: resolvedState = .interrupted
                case .unstarted: resolvedState = .unstarted
                case .running: resolvedState = .running
                }
            } else {
                resolvedState = .unstarted
            }
            return LedgerStepItem(
                spec: spec,
                state: resolvedState,
                detail: result?.detail
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ledgerHeader

            Divider().overlay(Theme.Colors.border)

            if !isCompactLayout {
                columnHeaders
                Divider().overlay(Theme.Colors.borderSubtle)
            }

            ForEach(Array(ledgerSteps.enumerated()), id: \.element.id) { idx, step in
                RepairRecordStepRow(
                    step: step,
                    isCompact: isCompactLayout,
                    isEvenRow: idx.isMultiple(of: 2),
                    isExpanded: expandedStepIDs.contains(step.id),
                    onToggleExpand: onToggleExpand.map { callback in { callback(step.id) } }
                )

                if idx < ledgerSteps.count - 1 {
                    Divider().overlay(Theme.Colors.borderSubtle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedLedger()
    }

    private var ledgerHeader: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: headerStatus.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(headerStatus.color)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("REPAIR RECORD")
                        .font(Theme.Typography.sectionEyebrow)
                        .tracking(0.72)
                        .foregroundStyle(Theme.Colors.textMuted)
                    Text(headerStatus.title)
                        .font(Theme.Typography.heading)
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
            }

            Spacer(minLength: Theme.Spacing.medium)

            HStack(spacing: Theme.Spacing.small) {
                if let duration = runRecord?.formattedDuration {
                    Text(duration)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Colors.textMuted)
                }

                Text(modeBadge.label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(modeBadge.color)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, 3)
                    .background(modeBadge.color.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .stroke(modeBadge.color.opacity(0.35), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var columnHeaders: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            Text("#")
                .font(Theme.Typography.sectionEyebrow)
                .tracking(0.72)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(width: 28, alignment: .leading)

            Text("STEP & SCOPE")
                .font(Theme.Typography.sectionEyebrow)
                .tracking(0.72)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(width: 224, alignment: .leading)

            Text("DETAIL / EFFECT")
                .font(Theme.Typography.sectionEyebrow)
                .tracking(0.72)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("OUTCOME")
                .font(Theme.Typography.sectionEyebrow)
                .tracking(0.72)
                .foregroundStyle(Theme.Colors.textMuted)
                .frame(width: 136, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
        .background(Theme.Colors.surfaceRecessed.opacity(0.65))
    }

    private var headerStatus: (title: String, icon: String, color: Color) {
        switch workflowState {
        case .idle:
            return ("9-Step Repair Sequence", "list.number", Theme.Colors.textSecondary)
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
            let title = isPreviewRun ? "Running read-only preview…" : "Executing repair sequence…"
            return (title, "bolt.horizontal.circle.fill", Theme.Colors.primary)
        case .canceling:
            return ("Stopping repair safely…", "hand.raised.fill", Theme.Colors.warning)
        case .canceled:
            return ("Stopped before completion", "stop.circle.fill", Theme.Colors.warning)
        case .failed(let message):
            return ("Repair stopped safely — \(message)", "xmark.circle.fill", Theme.Colors.error)
        case .completed:
            if isPreviewRun {
                let hasAdvisories = ledgerSteps.contains { $0.state == .warning || $0.state == .failed }
                return (
                    hasAdvisories ? "Preview completed with advisories" : "Preview completed — no files or settings modified",
                    hasAdvisories ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    hasAdvisories ? Theme.Colors.warning : Theme.Colors.success
                )
            }
            let hasNotes = ledgerSteps.contains { $0.state == .warning || $0.state == .skipped }
            return (
                hasNotes ? "Repair completed with notes" : "Repair completed — Zoom launched in sandbox mode",
                hasNotes ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                hasNotes ? Theme.Colors.warning : Theme.Colors.success
            )
        }
    }

    private var modeBadge: (label: String, color: Color) {
        switch workflowState {
        case .idle:
            return ("Ready", Theme.Colors.textSecondary)
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
            return (isPreviewRun ? "Previewing" : "Live Repair", Theme.Colors.primary)
        case .canceling:
            return ("Stopping", Theme.Colors.warning)
        case .canceled:
            return ("Interrupted", Theme.Colors.warning)
        case .failed:
            return ("Stopped Safely", Theme.Colors.error)
        case .completed:
            if isPreviewRun {
                return ("Preview Record", Theme.Colors.primary)
            }
            return ("Completed", Theme.Colors.success)
        }
    }
}

private struct RepairRecordStepRow: View {
    let step: RepairRecordLedgerView.LedgerStepItem
    let isCompact: Bool
    let isEvenRow: Bool
    let isExpanded: Bool
    let onToggleExpand: (() -> Void)?

    private var indexLabel: String {
        String(format: "%02d", step.index)
    }

    private var detailText: String {
        if let detail = step.detail, !detail.isEmpty {
            return detail
        }
        return step.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Group {
                if isCompact {
                    compactRow
                } else {
                    wideRow
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.summary)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Text(step.commandSummary)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Colors.textMuted)
                        .textSelection(.enabled)
                }
                .padding(.leading, isCompact ? 36 : 268)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small + 3)
        .frame(minHeight: Theme.Window.rowMinHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleExpand?()
        }
        .overlay(alignment: .leading) {
            if step.state == .running {
                Rectangle()
                    .fill(Theme.Colors.primary)
                    .frame(width: 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(indexLabel), \(step.name), \(step.scope). Status: \(outcomeText). \(detailText)")
    }

    private var wideRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Text(indexLabel)
                .font(Theme.Typography.stepIndex)
                .foregroundStyle(step.state == .running ? Theme.Colors.primary : Theme.Colors.textMuted)
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(step.name)
                        .font(Theme.Typography.stepTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)

                    if step.requiresAdmin {
                        adminBadge
                    }
                }

                Text(step.scope)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMuted)
                    .lineLimit(1)
            }
            .frame(width: 224, alignment: .leading)

            Text(detailText)
                .font(Theme.Typography.body)
                .foregroundStyle(detailColor)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            outcomeBadge
                .frame(width: 136, alignment: .trailing)
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Text(indexLabel)
                    .font(Theme.Typography.stepIndex)
                    .foregroundStyle(step.state == .running ? Theme.Colors.primary : Theme.Colors.textMuted)
                    .frame(width: 28, alignment: .leading)

                Text(step.name)
                    .font(Theme.Typography.stepTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)

                if step.requiresAdmin {
                    adminBadge
                }

                Spacer(minLength: Theme.Spacing.small)

                outcomeBadge
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xSmall) {
                Text("\(step.scope) · \(detailText)")
                    .font(Theme.Typography.body)
                    .foregroundStyle(detailColor)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
            }
            .padding(.leading, 36)
        }
    }

    private var adminBadge: some View {
        Text("Admin")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.Colors.warning.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private var outcomeBadge: some View {
        HStack(spacing: 5) {
            if step.state == .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: outcomeIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(outcomeColor)
                    .accessibilityHidden(true)
            }

            Text(outcomeText)
                .font(Theme.Typography.label)
                .foregroundStyle(outcomeColor)
                .lineLimit(1)
        }
    }

    private var rowBackground: Color {
        switch step.state {
        case .running:
            return Theme.Colors.surfaceElevated
        case .failed:
            return Theme.Colors.error.opacity(0.06)
        case .interrupted:
            return Theme.Colors.warning.opacity(0.05)
        default:
            return isEvenRow ? Theme.Colors.surface : Theme.Colors.surfaceRecessed.opacity(0.35)
        }
    }

    private var detailColor: Color {
        switch step.state {
        case .failed:
            return Theme.Colors.error
        case .warning, .interrupted:
            return Theme.Colors.textPrimary
        case .running:
            return Theme.Colors.textPrimary
        case .unstarted:
            return Theme.Colors.textSecondary
        case .succeeded, .skipped:
            return step.detail != nil ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
        }
    }

    private var outcomeIcon: String {
        switch step.state {
        case .unstarted: return "circle"
        case .running: return "clock.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var outcomeColor: Color {
        switch step.state {
        case .unstarted: return Theme.Colors.textMuted
        case .running: return Theme.Colors.primary
        case .succeeded: return Theme.Colors.success
        case .warning, .skipped, .interrupted: return Theme.Colors.warning
        case .failed: return Theme.Colors.error
        }
    }

    private var outcomeText: String {
        switch step.state {
        case .unstarted: return "Not started"
        case .running: return "Running…"
        case .succeeded: return "Succeeded"
        case .warning: return "Warning"
        case .skipped: return "Skipped"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }
}

struct BackupProvenanceBar: View {
    let currentRunBackupPath: String?
    let previousBackupPath: String?
    let onRevealBackup: () -> Void

    var body: some View {
        if let activeBackupPath = currentRunBackupPath {
            provenanceRow(
                icon: "checkmark.shield.fill",
                iconColor: Theme.Colors.success,
                label: "Backup created in this run",
                path: activeBackupPath,
                buttonTitle: "Reveal in Finder"
            )
        } else if let olderBackupPath = previousBackupPath {
            provenanceRow(
                icon: "clock.arrow.circlepath",
                iconColor: Theme.Colors.textSecondary,
                label: "Previous backup available (not created in this run)",
                path: olderBackupPath,
                buttonTitle: "Reveal Previous Backup"
            )
        }
    }

    private func provenanceRow(
        icon: String,
        iconColor: Color,
        label: String,
        path: String,
        buttonTitle: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                    Text(label)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textPrimary)
                }

                Text(path)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onRevealBackup) {
                    Label(buttonTitle, systemImage: "folder")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                    Text(label)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Button(action: onRevealBackup) {
                        Label(buttonTitle, systemImage: "folder")
                    }
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                }
                Text(path)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedLedger()
    }
}
