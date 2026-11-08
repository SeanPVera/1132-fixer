import SwiftUI

// MARK: - State-derived composition (pure, unit-tested)

/// Which composition the workspace shows. It is derived only from existing view-model state;
/// it never drives or alters the workflow.
enum WorkspaceStage: Equatable {
    /// No run yet: system checks plus the plan and one primary action.
    case ready
    /// A preview, sandbox launch, or repair is executing or stopping.
    case running
    /// A run finished, failed, or was stopped; its record and a retry stay on screen.
    case results

    init(workflowState: AppViewModel.WorkflowState, isRunning: Bool) {
        if isRunning || workflowState.isActiveRun {
            self = .running
            return
        }
        switch workflowState {
        case .canceling:
            self = .running
        case .completed, .completedWithWarnings, .failed, .canceled:
            self = .results
        default:
            self = .ready
        }
    }
}

/// Progress through the ledger, derived from step states.
struct RunProgressSummary: Equatable {
    let finishedCount: Int
    let totalCount: Int
    let currentStepName: String?
    /// 1-based position of the running step, matching `WorkspaceSummary.currentStepText`.
    let currentStepNumber: Int?

    init(items: [RepairRecordLedgerView.LedgerStepItem]) {
        self.init(states: items.map { ($0.name, $0.state) })
    }

    init(states: [(name: String, state: AppViewModel.WorkflowProgress.StepState)]) {
        totalCount = states.count
        finishedCount = states.filter { entry in
            switch entry.state {
            case .succeeded, .warning, .failed, .skipped, .interrupted: return true
            case .unstarted, .running: return false
            }
        }.count
        if let runningIndex = states.firstIndex(where: { $0.state == .running }) {
            currentStepName = states[runningIndex].name
            currentStepNumber = runningIndex + 1
        } else {
            currentStepName = nil
            currentStepNumber = nil
        }
    }

    var fraction: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(finishedCount) / Double(totalCount), 0), 1)
    }

    var label: String {
        guard totalCount > 0 else { return "Preparing steps…" }
        if let currentStepName, let currentStepNumber {
            return "Step \(currentStepNumber) of \(totalCount) · \(currentStepName)"
        }
        return "\(finishedCount) of \(totalCount) steps finished"
    }
}

enum WorkspaceLayoutMetrics {
    static let sidebarWidth: CGFloat = Theme.Window.sidebarWidth
    /// Below this window width the sidebar folds back into the single-column layout.
    static let sidebarBreakpoint: CGFloat = Theme.Window.sidebarBreakpoint
    static let liveLogLineCount = 6
}

// MARK: - Preflight sidebar

/// Leading column: live system checks, the Zoom location, and support tools.
struct PreflightSidebar<ZoomLocation: View>: View {
    let preflight: AppViewModel.PreflightInfo
    let isRunning: Bool
    let logCount: Int
    let isReportingBug: Bool
    let zoomLocation: ZoomLocation
    let onShowDetails: () -> Void
    let onShowLog: () -> Void
    let onExportDiagnostics: () -> Void
    let onReportBug: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.majorSection) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                    // Re-running checks stays in the status summary's Recheck button
                    // (disabled while loading) to avoid a duplicate control.
                    Text("System checks")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    checkList

                    Button(action: onShowDetails) {
                        Label("System check details", systemImage: "checklist")
                    }
                    .buttonStyle(QuietLinkButtonStyle(color: Theme.Colors.link))
                }

                zoomLocation

                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                    Text("Support")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Button(action: onShowLog) {
                        Label(logCount > 0 ? "Activity log (\(logCount))" : "Activity log", systemImage: "text.alignleft")
                            .monospacedDigit()
                    }
                    Button(action: onExportDiagnostics) {
                        Label("Export diagnostics…", systemImage: "square.and.arrow.up")
                    }
                    Button(action: onReportBug) {
                        Label("Report a bug…", systemImage: "ladybug")
                    }
                    .disabled(isReportingBug)
                }
                .buttonStyle(QuietLinkButtonStyle(color: Theme.Colors.textSecondary))
            }
            .padding(Theme.Spacing.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: WorkspaceLayoutMetrics.sidebarWidth)
        .background(Theme.Colors.surface)
    }

    @ViewBuilder
    private var checkList: some View {
        if case .loading = preflight.status, preflight.checks.isEmpty {
            HStack(spacing: Theme.Spacing.s8) {
                ProgressView().controlSize(.small)
                Text("Checking this Mac…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                ForEach(preflight.checks) { check in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
                        Image(systemName: Self.symbol(for: check))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Self.tone(for: check).color)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.label)
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text(check.value)
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Self.statusWord(for: check))
                }
            }
        }
    }

    static func tone(for check: AppViewModel.PreflightInfo.Check) -> StatusTone {
        if check.isBlocking { return .error }
        if check.isWarning { return .warning }
        return .success
    }

    static func symbol(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "xmark.octagon.fill" }
        if check.isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    static func statusWord(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "Blocking" }
        if check.isWarning { return "Warning" }
        return "Passed"
    }
}

// MARK: - Running composition

/// Determinate progress bar derived from step states, shown only while a run is active.
/// The step name and count are already narrated by the status summary above, so the
/// strip shows text only while stopping.
struct RunProgressStrip: View {
    let summary: RunProgressSummary
    let isCanceling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
            ProgressView(value: summary.fraction)
                .progressViewStyle(.linear)
                .tint(isCanceling ? Theme.Colors.warning : Theme.Colors.primary)
                .accessibilityLabel("Run progress")
                .accessibilityValue(summary.label)
            if isCanceling {
                Text("Stopping after the current step")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
    }
}

/// The newest activity-log lines in a recessed well, with access to the full log sheet.
struct LiveLogTail: View {
    let entries: [LogEntry]
    let onOpenFullLog: () -> Void

    private var tail: ArraySlice<LogEntry> { entries.suffix(WorkspaceLayoutMetrics.liveLogLineCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live activity")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Open full log", action: onOpenFullLog)
                    .buttonStyle(QuietLinkButtonStyle(color: Theme.Colors.link))
            }
            VStack(alignment: .leading, spacing: 2) {
                if tail.isEmpty {
                    Text("Waiting for the first step…")
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    ForEach(tail) { entry in
                        Text(entry.formattedLine)
                            .foregroundStyle(entry.id == tail.last?.id ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(Theme.Typography.mono)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.s12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.Colors.surfaceRecessed)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
    }
}
