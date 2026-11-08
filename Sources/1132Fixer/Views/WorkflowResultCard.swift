import SwiftUI

/// The kind of run that populated the repair record, derived from the run's title.
enum RunKind: Equatable {
    case preview
    case sandboxLaunch
    case repair

    static let sandboxLaunchTitle = "Sandbox-only Zoom launch"

    init?(record: RunRecord?) {
        guard let title = record?.title else { return nil }
        if title == Self.sandboxLaunchTitle {
            self = .sandboxLaunch
        } else if title.localizedCaseInsensitiveContains("dry run") || title.localizedCaseInsensitiveContains("preview") {
            self = .preview
        } else {
            self = .repair
        }
    }

    var label: String {
        switch self {
        case .preview: return "Preview"
        case .sandboxLaunch: return "Sandbox launch"
        case .repair: return "Repair"
        }
    }

    var activeLabel: String {
        switch self {
        case .preview: return "Previewing"
        case .sandboxLaunch: return "Launching"
        case .repair: return "Repairing"
        }
    }
}

extension AppViewModel.WorkflowState {
    /// True while a preview, sandbox launch, or repair run is executing a step.
    var isActiveRun: Bool {
        switch self {
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
            return true
        case .idle, .completed, .completedWithWarnings, .failed, .canceling, .canceled:
            return false
        }
    }
}

extension AppViewModel.WorkflowProgress.StepState {
    var outcomeText: String {
        switch self {
        case .unstarted: return "Not started"
        case .running: return "Running…"
        case .succeeded: return "Succeeded"
        case .warning: return "Warning"
        case .skipped: return "Skipped"
        case .interrupted: return "Interrupted"
        case .failed: return "Failed"
        }
    }

    var outcomeSymbol: String {
        switch self {
        case .unstarted: return "circle"
        case .running: return "clock.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tone: StatusTone {
        switch self {
        case .unstarted: return .neutral
        case .running: return .active
        case .succeeded: return .success
        case .warning, .skipped, .interrupted: return .warning
        case .failed: return .error
        }
    }

    /// Finished in any way (as opposed to not started or still running).
    var isSettled: Bool {
        switch self {
        case .unstarted, .running: return false
        case .succeeded, .warning, .skipped, .interrupted, .failed: return true
        }
    }
}

/// Shared column geometry so headers, rows, and expanded detail stay aligned.
private enum RecordColumns {
    static let disclosure: CGFloat = 12
    static let index: CGFloat = 24
    static let operation: CGFloat = 224
    static let outcome: CGFloat = 136
    static let gap: CGFloat = Theme.Spacing.s12

    static var sequence: CGFloat { disclosure + Theme.Spacing.s8 + index }
    /// Leading inset that aligns expanded content with the operation column.
    static var detailInset: CGFloat { sequence + gap }
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

    let items: [LedgerStepItem]
    let workflowState: AppViewModel.WorkflowState
    let runRecord: RunRecord?
    var expandedStepIDs: Set<String> = []
    var onToggleExpand: ((String) -> Void)? = nil
    let isCompactLayout: Bool

    /// Resolves the canonical step list against live progress and recorded results.
    static func makeItems(
        steps: [AppViewModel.WorkflowProgress.Step],
        stepResults: [AppViewModel.StepResult],
        runRecord: RunRecord?
    ) -> [LedgerStepItem] {
        let effectiveResults: [AppViewModel.StepResult]
        if let recordSteps = runRecord?.steps, !recordSteps.isEmpty {
            effectiveResults = recordSteps
        } else {
            effectiveResults = stepResults
        }

        let quickLaunch = RunKind(record: runRecord) == .sandboxLaunch
        let canonical = RepairStepSpec.canonicalSteps().filter {
            !quickLaunch || ["validate", "closeZoom", "mediaAccess", "launch"].contains($0.id)
        }
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

    private var runKind: RunKind? {
        RunKind(record: runRecord)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s12) {
            sectionHeader

            VStack(alignment: .leading, spacing: 0) {
                if !isCompactLayout {
                    columnHeaders
                    Divider().overlay(Theme.Signal.border)
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { idx, step in
                    RepairRecordStepRow(
                        step: step,
                        isCompact: isCompactLayout,
                        isExpanded: expandedStepIDs.contains(step.id),
                        onToggleExpand: onToggleExpand.map { callback in { callback(step.id) } }
                    )

                    if idx < items.count - 1 {
                        Divider().overlay(Theme.Signal.border)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ledgerContainer()
        }
    }

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Text("Repair record")
                .font(Theme.Typography.sectionHeading)
                .foregroundStyle(Theme.Signal.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text("\(items.count) steps")
                .font(Theme.Typography.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Signal.textSecondary)

            Spacer(minLength: Theme.Spacing.s12)

            if let duration = runRecord?.formattedDuration {
                Text(duration)
                    .font(Theme.Typography.mono)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .accessibilityLabel("Duration \(duration)")
            }

            if let runKind {
                let isLive = workflowState.isActiveRun || workflowState == .canceling
                StatusTag(
                    text: isLive ? runKind.activeLabel : runKind.label,
                    tone: isLive ? .active : .neutral
                )
            }
        }
    }

    private var columnHeaders: some View {
        HStack(alignment: .firstTextBaseline, spacing: RecordColumns.gap) {
            Text("#")
                .padding(.leading, RecordColumns.disclosure + Theme.Spacing.s8)
                .frame(width: RecordColumns.sequence, alignment: .leading)

            Text("Operation")
                .frame(width: RecordColumns.operation, alignment: .leading)

            Text("Effect")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Outcome")
                .frame(width: RecordColumns.outcome, alignment: .trailing)
        }
        .font(Theme.Typography.metadata)
        .foregroundStyle(Theme.Signal.textSecondary)
        .padding(.horizontal, Theme.Spacing.s16)
        .padding(.vertical, Theme.Spacing.s8)
        .accessibilityHidden(true)
    }
}

private struct RepairRecordStepRow: View {
    let step: RepairRecordLedgerView.LedgerStepItem
    let isCompact: Bool
    let isExpanded: Bool
    let onToggleExpand: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var indexLabel: String {
        String(format: "%02d", step.index)
    }

    private var detailText: String {
        if let detail = step.detail, !detail.isEmpty {
            return detail
        }
        return step.summary
    }

    private var hasRecordedDetail: Bool {
        guard let detail = step.detail else { return false }
        return !detail.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
            Group {
                if isCompact {
                    compactRow
                } else {
                    wideRow
                }
            }

            if isExpanded {
                expandedDetail
            }
        }
        .padding(.horizontal, Theme.Spacing.s16)
        .padding(.vertical, Theme.Spacing.s12)
        .frame(maxWidth: .infinity, minHeight: Theme.Window.rowMinHeight, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if let accent = leadingAccent {
                Rectangle()
                    .fill(accent)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(indexLabel), \(step.name), \(step.scope). Status: \(step.state.outcomeText). \(detailText)")
        .accessibilityAction(named: Text(isExpanded ? "Hide details" : "Show details")) { toggle() }
    }

    private func toggle() {
        guard let onToggleExpand else { return }
        if reduceMotion {
            onToggleExpand()
        } else {
            withAnimation(.easeInOut(duration: Theme.Motion.disclosureDuration)) {
                onToggleExpand()
            }
        }
    }

    // MARK: Layouts

    private var wideRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: RecordColumns.gap) {
            sequenceCell

            VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                operationTitle
                Text(step.scope)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: RecordColumns.operation, alignment: .leading)

            Text(detailText)
                .font(Theme.Typography.body)
                .foregroundStyle(detailColor)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            outcomeLabel
                .frame(width: RecordColumns.outcome, alignment: .trailing)
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
            HStack(alignment: .firstTextBaseline, spacing: RecordColumns.gap) {
                sequenceCell
                operationTitle
                Spacer(minLength: Theme.Spacing.s8)
                outcomeLabel
            }

            Text("\(step.scope) · \(detailText)")
                .font(Theme.Typography.body)
                .foregroundStyle(detailColor)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: isExpanded)
                .textSelection(.enabled)
                .padding(.leading, RecordColumns.detailInset)
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
            if hasRecordedDetail {
                Text(step.summary)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(step.commandSummary)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Signal.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, RecordColumns.detailInset)
        .transition(.opacity)
    }

    // MARK: Cells

    private var sequenceCell: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: RecordColumns.disclosure)
            }
            .buttonStyle(.plain)
            .disabled(onToggleExpand == nil)
            .help(isExpanded ? "Hide planned effect and command" : "Show planned effect and command")
            .accessibilityLabel(isExpanded ? "Hide details for \(step.name)" : "Show details for \(step.name)")

            Text(indexLabel)
                .font(Theme.Typography.mono)
                .monospacedDigit()
                .foregroundStyle(step.state == .running ? StatusTone.active.color : Theme.Signal.textSecondary)
                .frame(width: RecordColumns.index, alignment: .leading)
        }
        .frame(width: RecordColumns.sequence, alignment: .leading)
    }

    private var operationTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Text(step.name)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Signal.textPrimary)
                .lineLimit(1)

            if step.requiresAdmin {
                Label("Admin", systemImage: "lock.fill")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Signal.warning)
                    .help("Requires the administrator password prompt")
            }
        }
    }

    private var outcomeLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s4) {
            if step.state == .running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: step.state.outcomeSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(step.state.tone.color)
                    .accessibilityHidden(true)
            }

            Text(step.state.outcomeText)
                .font(Theme.Typography.label)
                .foregroundStyle(step.state.tone.color)
                .lineLimit(1)
        }
    }

    // MARK: State styling

    private var rowBackground: Color {
        if step.state == .running {
            return Theme.Signal.surfaceHover
        }
        if isHovering && onToggleExpand != nil {
            return Theme.Signal.surfaceHover
        }
        return .clear
    }

    /// A 2pt leading rule marks the row that needs the eye: the active step or a stopped/failed one.
    private var leadingAccent: Color? {
        switch step.state {
        case .running, .failed, .interrupted:
            return step.state.tone.color
        case .unstarted, .succeeded, .warning, .skipped:
            return nil
        }
    }

    private var detailColor: Color {
        switch step.state {
        case .failed:
            return Theme.Signal.error
        case .warning, .interrupted, .running:
            return Theme.Signal.textPrimary
        case .unstarted:
            return Theme.Signal.textSecondary
        case .succeeded, .skipped:
            return hasRecordedDetail ? Theme.Signal.textPrimary : Theme.Signal.textSecondary
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
                tone: .success,
                label: "Backup created in this run",
                path: activeBackupPath,
                buttonTitle: "Reveal in Finder"
            )
        } else if let olderBackupPath = previousBackupPath {
            provenanceRow(
                icon: "clock.arrow.circlepath",
                tone: .neutral,
                label: "Previous backup available (not created in this run)",
                path: olderBackupPath,
                buttonTitle: "Reveal previous backup"
            )
        }
    }

    private func provenanceRow(
        icon: String,
        tone: StatusTone,
        label: String,
        path: String,
        buttonTitle: String
    ) -> some View {
        let title = HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(label)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Signal.textPrimary)
        }

        let pathText = Text(path)
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Signal.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityLabel("Backup location: \(path)")

        let reveal = Button(action: onRevealBackup) {
            Label(buttonTitle, systemImage: "folder")
        }
        .buttonStyle(ThemedButtonStyle(variant: .secondary))

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.s12) {
                title
                pathText.frame(maxWidth: .infinity, alignment: .leading)
                reveal
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                HStack(alignment: .center, spacing: Theme.Spacing.s12) {
                    title
                    Spacer(minLength: Theme.Spacing.s8)
                    reveal
                }
                pathText
            }
        }
        .padding(.horizontal, Theme.Spacing.s16)
        .padding(.vertical, Theme.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ledgerContainer()
    }
}
