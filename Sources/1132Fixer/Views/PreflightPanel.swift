import SwiftUI

enum EnvironmentSupport {
    static let supportMatrix: [(label: String, supported: Bool)] = [
        ("Intel", true),
        ("Apple Silicon", true),
        ("macOS 13", true),
        ("macOS 14+", true),
        ("Wi-Fi", true),
        ("Ethernet", true),
        ("VPN", false),
    ]

}

/// Pinned workspace summary: system readiness before any run, the current run's outcome after.
/// A blocking or advisory preflight notice stays visible whenever no run is active.
struct WorkspaceSummary: View {
    let preflight: AppViewModel.PreflightInfo
    let workflowState: AppViewModel.WorkflowState
    let runRecord: RunRecord?
    let ledgerSteps: [RepairRecordLedgerView.LedgerStepItem]
    let isRunning: Bool
    let onRecheck: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Glyph {
        case progress
        case symbol(String)
    }

    private struct Descriptor {
        let heading: String
        let detail: String?
        let metadata: String?
        let glyph: Glyph
        let tone: StatusTone
    }

    private struct Notice {
        let title: String
        let value: String
        let symbol: String
        let tone: StatusTone
    }

    private var blockingChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter(\.isBlocking)
    }

    private var warningChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter { $0.isWarning && !$0.isBlocking }
    }

    private var passedChecks: [AppViewModel.PreflightInfo.Check] {
        preflight.checks.filter { !$0.isBlocking && !$0.isWarning }
    }

    private var isPreflightLoading: Bool {
        if case .loading = preflight.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s12) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s12) {
                glyphView

                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                    Text(descriptor.heading)
                        .font(Theme.Typography.statusHeadline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    if let detail = descriptor.detail {
                        Text(detail)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if let metadata = descriptor.metadata {
                        Text(metadata)
                            .font(Theme.Typography.metadata)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !isRunning {
                    Button(action: onRecheck) {
                        Label(isPreflightLoading ? "Checking…" : "Recheck", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QuietLinkButtonStyle())
                    .disabled(isPreflightLoading)
                    .help("Run the system checks again")
                }
            }

            if !isRunning, let notice {
                noticeRow(notice)
            }
        }
        .padding(.leading, Theme.Spacing.s16)
        .overlay(alignment: .leading) {
            // State-derived accent rule; decorative, the heading carries the meaning.
            // Only the rule's colour animates; text and layout update immediately (07-motion.md).
            Capsule()
                .fill(descriptor.tone.color)
                .frame(width: Theme.Status.accentRuleWidth)
                .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.controlFeedbackDuration), value: descriptor.tone)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Glyph

    @ViewBuilder
    private var glyphView: some View {
        switch descriptor.glyph {
        case .progress:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(descriptor.tone.color)
                .accessibilityHidden(true)
        }
    }

    // MARK: Notice

    private var notice: Notice? {
        guard case .ready = preflight.status else { return nil }
        if let blocker = blockingChecks.first {
            return Notice(title: "Blocked by \(blocker.label):", value: blocker.value, symbol: "xmark.octagon.fill", tone: .error)
        }
        if let warning = warningChecks.first {
            return Notice(title: "\(warning.label) advisory:", value: warning.value, symbol: "exclamationmark.triangle.fill", tone: .warning)
        }
        return nil
    }

    private func noticeRow(_ notice: Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice.tone.color)
                .accessibilityHidden(true)
            Text(notice.title)
                .font(Theme.Typography.label)
                .foregroundStyle(notice.tone.color)
            Text(notice.value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.s16)
        .padding(.vertical, Theme.Spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedPanel()
        .accessibilityElement(children: .combine)
    }

    // MARK: Descriptor

    private var descriptor: Descriptor {
        if workflowState == .idle {
            return readinessDescriptor
        }
        return runDescriptor
    }

    private var readinessDescriptor: Descriptor {
        switch preflight.status {
        case .loading:
            return Descriptor(
                heading: "Checking this Mac",
                detail: "Inspecting macOS, Zoom signature, network, backup capacity, and sandbox…",
                metadata: nil,
                glyph: .progress,
                tone: .active
            )
        case .error(let message):
            return Descriptor(
                heading: "System checks failed",
                detail: message,
                metadata: nil,
                glyph: .symbol("xmark.circle.fill"),
                tone: .error
            )
        case .ready:
            let total = preflight.checks.count
            let passed = passedChecks.count
            if !blockingChecks.isEmpty {
                let count = blockingChecks.count
                return Descriptor(
                    heading: "Repair blocked",
                    detail: "\(count) blocking \(count == 1 ? "issue" : "issues") · \(passed) of \(total) checks passed",
                    metadata: nil,
                    glyph: .symbol("xmark.octagon.fill"),
                    tone: .error
                )
            }
            if !warningChecks.isEmpty {
                let count = warningChecks.count
                return Descriptor(
                    heading: "Ready to repair",
                    detail: "\(count) \(count == 1 ? "advisory" : "advisories") · \(passed) of \(total) checks passed",
                    metadata: nil,
                    glyph: .symbol("exclamationmark.triangle.fill"),
                    tone: .warning
                )
            }
            return Descriptor(
                heading: "Ready to repair",
                detail: "All \(total) system checks passed. Nothing on this Mac changes until you review and start a repair.",
                metadata: nil,
                glyph: .symbol("checkmark.circle.fill"),
                tone: .success
            )
        }
    }

    private var runDescriptor: Descriptor {
        let kind = RunKind(record: runRecord) ?? .repair
        let hasFlaggedSteps = ledgerSteps.contains { $0.state == .warning || $0.state == .failed || $0.state == .skipped }

        switch workflowState {
        case .canceling:
            return Descriptor(
                heading: "Stopping safely",
                detail: currentStepText,
                metadata: runMetadata(kind),
                glyph: .symbol("hand.raised.fill"),
                tone: .warning
            )
        case .canceled:
            return Descriptor(
                heading: "Run stopped",
                detail: "Steps that did not run remain marked Not started.",
                metadata: runMetadata(kind),
                glyph: .symbol("stop.circle.fill"),
                tone: .warning
            )
        case .failed(let message):
            let runFailed = runRecord?.outcome == .failed
            return Descriptor(
                heading: runFailed ? "Run failed" : "Action failed",
                detail: message,
                metadata: runFailed ? runMetadata(kind) : nil,
                glyph: .symbol("xmark.circle.fill"),
                tone: .error
            )
        case .completed, .completedWithWarnings:
            let flagged = hasFlaggedSteps || workflowState == .completedWithWarnings
            switch kind {
            case .preview:
                return finishedDescriptor(
                    flagged: flagged,
                    cleanHeading: "Preview complete",
                    cleanDetail: "No files, network settings, or processes were modified.",
                    flaggedHeading: "Preview found advisories",
                    flaggedDetail: "Review the flagged steps below before starting a repair.",
                    kind: kind
                )
            case .sandboxLaunch:
                return finishedDescriptor(
                    flagged: flagged,
                    cleanHeading: "Zoom launched in sandbox",
                    cleanDetail: "Verify Zoom sign-in and media access.",
                    flaggedHeading: "Sandbox launch finished with warnings",
                    flaggedDetail: "Review the flagged steps below.",
                    kind: kind
                )
            case .repair:
                return finishedDescriptor(
                    flagged: flagged,
                    cleanHeading: "Repair complete",
                    cleanDetail: "Zoom relaunched in sandbox mode. Verify Zoom sign-in and media access.",
                    flaggedHeading: "Repair completed with notes",
                    flaggedDetail: "Review the flagged steps below.",
                    kind: kind
                )
            }
        case .idle,
            .preflight,
            .closingZoom,
            .spoofingMAC,
            .checkingNetwork,
            .backingUpState,
            .clearingState,
            .flushingDNS,
            .stoppingUpdaters,
            .checkingMediaAccess,
            .launchingZoom:
            let heading: String
            switch kind {
            case .preview: heading = "Previewing repair steps"
            case .sandboxLaunch: heading = "Launching Zoom in sandbox"
            case .repair: heading = "Repairing Zoom"
            }
            return Descriptor(
                heading: heading,
                detail: currentStepText,
                metadata: runMetadata(kind),
                glyph: .progress,
                tone: .active
            )
        }
    }

    private func finishedDescriptor(
        flagged: Bool,
        cleanHeading: String,
        cleanDetail: String,
        flaggedHeading: String,
        flaggedDetail: String,
        kind: RunKind
    ) -> Descriptor {
        Descriptor(
            heading: flagged ? flaggedHeading : cleanHeading,
            detail: flagged ? flaggedDetail : cleanDetail,
            metadata: runMetadata(kind),
            glyph: .symbol(flagged ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"),
            tone: flagged ? .warning : .success
        )
    }

    /// "Step 3 of 4: Media Access" — position within the steps this run actually covers.
    private var currentStepText: String? {
        guard let position = ledgerSteps.firstIndex(where: { $0.state == .running }) else { return nil }
        return "Step \(position + 1) of \(ledgerSteps.count): \(ledgerSteps[position].name)"
    }

    private func runMetadata(_ kind: RunKind) -> String {
        let settled = ledgerSteps.filter { $0.state.isSettled }.count
        var parts = [kind.label, "\(settled) of \(ledgerSteps.count) steps finished"]
        if let duration = runRecord?.formattedDuration {
            parts.append(duration)
        }
        return parts.joined(separator: " · ")
    }
}

struct SystemCheckDetailsSheet: View {
    let preflight: AppViewModel.PreflightInfo
    let zoomAppPath: String
    let isRunning: Bool
    let onRecheck: () -> Void
    let onClose: () -> Void

    private var supportedEnvironments: String {
        EnvironmentSupport.supportMatrix.filter { $0.supported }.map { $0.label }.joined(separator: ", ")
    }

    private var unsupportedEnvironments: String {
        EnvironmentSupport.supportMatrix.filter { !$0.supported }.map { $0.label }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s16) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                    Text("System check details")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Preflight verification for macOS, Zoom code signature, network state, backup capacity, and sandbox-exec.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Theme.Spacing.s12)

                Button(action: onRecheck) {
                    Label("Re-run checks", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .disabled(isRunning)
            }
            .padding(Theme.Spacing.s24)

            Divider().overlay(Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s24) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        subsectionTitle("Preflight checks")

                        VStack(spacing: 0) {
                            ForEach(Array(preflight.checks.enumerated()), id: \.element.id) { index, check in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s12) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s4) {
                                        Image(systemName: statusIcon(for: check))
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(tone(for: check).color)
                                            .accessibilityHidden(true)
                                        Text(statusText(for: check))
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(tone(for: check).color)
                                    }
                                    .frame(width: 96, alignment: .leading)

                                    Text(check.label)
                                        .font(Theme.Typography.label)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                        .frame(width: 136, alignment: .leading)

                                    Text(check.value)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, Theme.Spacing.s16)
                                .padding(.vertical, Theme.Spacing.s12)
                                .frame(minHeight: Theme.Window.rowMinHeight)
                                .accessibilityElement(children: .combine)

                                if index < preflight.checks.count - 1 {
                                    Divider().overlay(Theme.Colors.border)
                                }
                            }
                        }
                        .ledgerContainer(background: Theme.Colors.surfaceModal)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        subsectionTitle("Target Zoom bundle")

                        Text(zoomAppPath)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, Theme.Spacing.s16)
                            .padding(.vertical, Theme.Spacing.s12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ledgerContainer(background: Theme.Colors.surfaceModal)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        subsectionTitle("Supported environments")

                        environmentRow(symbol: "checkmark.circle.fill", tone: .success, title: "Supported:", value: supportedEnvironments)
                        environmentRow(symbol: "xmark.circle.fill", tone: .error, title: "Not supported:", value: unsupportedEnvironments)
                    }
                }
                .padding(Theme.Spacing.s24)
            }

            Divider().overlay(Theme.Colors.border)

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Spacing.s24)
            .padding(.vertical, Theme.Spacing.s16)
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 460, idealHeight: 560, alignment: .topLeading)
        .background(Theme.Colors.surfaceModal)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
    }

    private func subsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Colors.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func environmentRow(symbol: String, tone: StatusTone, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "xmark.circle.fill" }
        if check.isWarning { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private func tone(for check: AppViewModel.PreflightInfo.Check) -> StatusTone {
        if check.isBlocking { return .error }
        if check.isWarning { return .warning }
        return .success
    }

    private func statusText(for check: AppViewModel.PreflightInfo.Check) -> String {
        if check.isBlocking { return "Blocked" }
        if check.isWarning { return "Advisory" }
        return "Passed"
    }
}
