import Foundation

/// Owns the single active workflow token. A stale task cannot clear a newer run.
struct WorkflowRunGate {
    private(set) var activeRunID: UUID?

    var isActive: Bool { activeRunID != nil }

    mutating func begin() -> UUID? {
        guard activeRunID == nil else { return nil }
        let runID = UUID()
        activeRunID = runID
        return runID
    }

    mutating func finish(_ runID: UUID) -> Bool {
        guard activeRunID == runID else { return false }
        activeRunID = nil
        return true
    }
}

/// Snapshot of system readiness and preflight checks for the selected Zoom bundle.
struct ReadinessSnapshot: Equatable {
    enum State: String, Equatable {
        case notChecked
        case checking
        case ready
        case attentionRequired
        case blocked

        var badgeLabel: String {
            switch self {
            case .notChecked: return "Not Checked"
            case .checking: return "Checking…"
            case .ready: return "Ready"
            case .attentionRequired: return "Attention Needed"
            case .blocked: return "Blocked"
            }
        }
    }

    var state: State
    var checkedAt: Date?
    var selectedAppPath: String
    var isCustomLocation: Bool
    var checks: [AppViewModel.PreflightInfo.Check]

    var blockingChecks: [AppViewModel.PreflightInfo.Check] {
        checks.filter(\.isBlocking)
    }

    var warningChecks: [AppViewModel.PreflightInfo.Check] {
        checks.filter { $0.isWarning && !$0.isBlocking }
    }

    var passingChecks: [AppViewModel.PreflightInfo.Check] {
        checks.filter { !$0.isWarning && !$0.isBlocking }
    }

    var canRepair: Bool {
        switch state {
        case .ready, .attentionRequired:
            return blockingChecks.isEmpty
        case .notChecked, .checking, .blocked:
            return false
        }
    }

    var headline: String {
        switch state {
        case .notChecked:
            return "System checks have not run yet"
        case .checking:
            return "Checking Zoom bundle, sandbox profile, and network…"
        case .ready:
            return "Ready to repair Zoom error 1132"
        case .attentionRequired:
            return "Ready to repair with \(warningChecks.count) advisory \(warningChecks.count == 1 ? "notice" : "notices")"
        case .blocked:
            if let firstBlocking = blockingChecks.first {
                return "Repair blocked: \(firstBlocking.label)"
            }
            return "Repair blocked until required checks pass"
        }
    }

    var subheadline: String {
        switch state {
        case .notChecked:
            return "Run Check Again to verify your Zoom installation and system readiness."
        case .checking:
            return "Verifying code signature, sandbox profile compilation, backup storage, and network route."
        case .ready:
            return "Verified \(selectedAppPath). A recovery backup will be created before any local state is reset."
        case .attentionRequired:
            let advisories = warningChecks.map { "\($0.label): \($0.value)" }.joined(separator: " • ")
            return advisories.isEmpty
                ? "Non-blocking advisories were found. You can still review and run the repair."
                : advisories
        case .blocked:
            let blockers = blockingChecks.map { "\($0.label): \($0.value)" }.joined(separator: " • ")
            return blockers.isEmpty
                ? "Select a valid, Apple-notarized Zoom.app bundle and ensure sufficient disk space."
                : blockers
        }
    }

    static func initial(selectedAppPath: String, isCustomLocation: Bool) -> ReadinessSnapshot {
        ReadinessSnapshot(
            state: .notChecked,
            checkedAt: nil,
            selectedAppPath: selectedAppPath,
            isCustomLocation: isCustomLocation,
            checks: []
        )
    }

    static func checking(selectedAppPath: String, isCustomLocation: Bool) -> ReadinessSnapshot {
        ReadinessSnapshot(
            state: .checking,
            checkedAt: nil,
            selectedAppPath: selectedAppPath,
            isCustomLocation: isCustomLocation,
            checks: []
        )
    }

    static func from(
        preflight: AppViewModel.PreflightInfo,
        selectedAppPath: String,
        isCustomLocation: Bool,
        checkedAt: Date = Date()
    ) -> ReadinessSnapshot {
        switch preflight.status {
        case .loading:
            return .checking(selectedAppPath: selectedAppPath, isCustomLocation: isCustomLocation)
        case .error(let message):
            return ReadinessSnapshot(
                state: .blocked,
                checkedAt: checkedAt,
                selectedAppPath: selectedAppPath,
                isCustomLocation: isCustomLocation,
                checks: [
                    .init(id: "error", label: "Preflight", value: message, isWarning: true, isBlocking: true)
                ]
            )
        case .ready:
            let hasBlockers = preflight.checks.contains(where: \.isBlocking)
            let hasWarnings = preflight.checks.contains(where: \.isWarning)
            let resolvedState: State
            if hasBlockers {
                resolvedState = .blocked
            } else if hasWarnings {
                resolvedState = .attentionRequired
            } else {
                resolvedState = .ready
            }
            return ReadinessSnapshot(
                state: resolvedState,
                checkedAt: checkedAt,
                selectedAppPath: selectedAppPath,
                isCustomLocation: isCustomLocation,
                checks: preflight.checks
            )
        }
    }
}

/// Canonical specification for a single step in the 9-step repair ledger.
struct RepairStepSpec: Identifiable, Equatable {
    let index: Int
    let id: String
    let name: String
    let scope: String
    let requiresAdmin: Bool
    let plannedSummary: String
    let commandSummary: String

    static func canonicalSteps(macSpoofingDisabled: Bool = ShellCommands.isMacSpoofingDisabledForCurrentOS()) -> [RepairStepSpec] {
        [
            RepairStepSpec(
                index: 1,
                id: "validate",
                name: "Safety Check",
                scope: "Bundle & Sandbox",
                requiresAdmin: false,
                plannedSummary: "Verify Zoom bundle signature (Team ID BJ4HAAB9B3) and compile the sandbox-exec launch profile.",
                commandSummary: "codesign --verify & sandbox-exec profile validation"
            ),
            RepairStepSpec(
                index: 2,
                id: "closeZoom",
                name: "Close Zoom",
                scope: "User Session",
                requiresAdmin: false,
                plannedSummary: "Quit running Zoom processes cleanly before backing up or modifying any files.",
                commandSummary: "osascript quit / killall zoom.us"
            ),
            RepairStepSpec(
                index: 3,
                id: "backup",
                name: "Backup State",
                scope: "~/Library/Application Support",
                requiresAdmin: false,
                plannedSummary: "Copy ~/Library/Application Support/zoom.us to a timestamped 0700 recovery folder (fail-closed).",
                commandSummary: "ditto ~/Library/Application Support/zoom.us ~/.1132-fixer-backups/..."
            ),
            RepairStepSpec(
                index: 4,
                id: "network",
                name: macSpoofingDisabled ? "Network Check" : "MAC Spoof & Network",
                scope: "Network & Admin",
                requiresAdmin: true,
                plannedSummary: macSpoofingDisabled
                    ? "Check active default route and rotate Private Wi-Fi Address when supported on Apple Silicon."
                    : "Randomize active network interface MAC address and cycle the network service.",
                commandSummary: macSpoofingDisabled
                    ? "route -n get default & networksetup private address rotation"
                    : "ifconfig lladdr & networksetup service cycle (Administrator)"
            ),
            RepairStepSpec(
                index: 5,
                id: "resetData",
                name: "Clear Local State",
                scope: "User Library",
                requiresAdmin: false,
                plannedSummary: "Remove cached Zoom preferences, containers, logs, and device identifiers in ~/Library.",
                commandSummary: "Remove ~/Library/{Application Support,Caches,Preferences,Logs}/zoom*"
            ),
            RepairStepSpec(
                index: 6,
                id: "dns",
                name: "DNS Flush",
                scope: "Administrator",
                requiresAdmin: true,
                plannedSummary: "Flush system DNS cache and restart mDNSResponder using the single administrator authorization.",
                commandSummary: "dscacheutil -flushcache & killall -HUP mDNSResponder (Administrator)"
            ),
            RepairStepSpec(
                index: 7,
                id: "updaters",
                name: "Stop Updaters",
                scope: "User LaunchAgents",
                requiresAdmin: false,
                plannedSummary: "Unload Zoom background updater LaunchAgents for the current login session without deleting plists.",
                commandSummary: "launchctl bootout gui/$UID us.zoom.ZoomAutoUpdater"
            ),
            RepairStepSpec(
                index: 8,
                id: "mediaAccess",
                name: "Camera & Mic",
                scope: "Privacy & Security",
                requiresAdmin: false,
                plannedSummary: "Check Camera and Microphone permissions for 1132 Fixer so sandboxed Zoom inherits A/V access.",
                commandSummary: "AVCaptureDevice authorization check (60s prompt timeout)"
            ),
            RepairStepSpec(
                index: 9,
                id: "launch",
                name: "Launch Zoom",
                scope: "Sandbox Exec",
                requiresAdmin: false,
                plannedSummary: "Re-verify the Zoom binary and launch it inside sandbox-exec with isolated HOME and user keychain.",
                commandSummary: "sandbox-exec -f <profile> <Zoom.app>/Contents/MacOS/zoom.us"
            ),
        ]
    }
}

/// Frozen repair plan presented in the review sheet before any repair starts.
struct RepairPlan: Identifiable, Equatable {
    struct AffectedLocation: Identifiable, Equatable {
        let id: String
        let label: String
        let path: String
        let action: String
        let requiresAdmin: Bool
    }

    let id: UUID
    let createdAt: Date
    let selectedAppPath: String
    let isCustomLocation: Bool
    let readiness: ReadinessSnapshot
    let steps: [RepairStepSpec]
    let affectedLocations: [AffectedLocation]
    let safetyGuarantees: [String]

    var adminStepCount: Int {
        steps.filter(\.requiresAdmin).count
    }

    /// Network identity reset (Step 4) and DNS cache flush (Step 6) are consolidated into a
    /// single privileged administrator session so the user is prompted at most once per run.
    var adminPromptCount: Int {
        steps.contains(where: \.requiresAdmin) ? 1 : 0
    }

    static func build(
        readiness: ReadinessSnapshot,
        selectedAppPath: String,
        isCustomLocation: Bool,
        macSpoofingDisabled: Bool = ShellCommands.isMacSpoofingDisabledForCurrentOS(),
        createdAt: Date = Date()
    ) -> RepairPlan {
        let steps = RepairStepSpec.canonicalSteps(macSpoofingDisabled: macSpoofingDisabled)
        let locations: [AffectedLocation] = [
            AffectedLocation(
                id: "zoom-bundle",
                label: "Target Zoom Bundle",
                path: selectedAppPath,
                action: "Verified read-only; launched via sandbox-exec in Step 9",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "backup-dir",
                label: "Recovery Backup Store",
                path: "~/Library/Application Support/1132Fixer/Backups",
                action: "New timestamped backup created in Step 3 before any deletion",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "user-zoom-data",
                label: "User Zoom State",
                path: "~/Library/Application Support/zoom.us, ~/Library/Caches/us.zoom.xos, ~/Library/Preferences/us.zoom.xos.plist, ~/Library/Saved Application State/us.zoom.xos.savedState",
                action: "Backed up first, then cleared in Step 5 (unprivileged)",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "user-zoom-logs",
                label: "Zoom Local Logs",
                path: "~/Library/Logs/zoom.us.log*",
                action: "Permanently removed in Step 5 (not included in backup)",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "updaters",
                label: "Zoom Auto-Updater Session",
                path: "~/Library/LaunchAgents/us.zoom.*",
                action: "Unloaded for current login session only in Step 7; plist files are preserved",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "network-dns",
                label: "Network & DNS Cache",
                path: "Active default-route interface & mDNSResponder",
                action: "Updated in Steps 4 and 6 via a single macOS Administrator authorization prompt",
                requiresAdmin: true
            ),
        ]
        let guarantees = [
            "Fail-closed: If Safety Check, Close Zoom, or Backup State fails, the workflow stops immediately before any data or network change.",
            "Unprivileged file reset: Local Zoom data removal runs strictly as your user account inside your validated home directory.",
            "Sandboxed launch only: Zoom is always launched under sandbox-exec with your login keychain remained accessible.",
        ]
        return RepairPlan(
            id: UUID(),
            createdAt: createdAt,
            selectedAppPath: selectedAppPath,
            isCustomLocation: isCustomLocation,
            readiness: readiness,
            steps: steps,
            affectedLocations: locations,
            safetyGuarantees: guarantees
        )
    }
}

/// Complete record of a single workflow run, including per-run backup provenance.
struct RunRecord: Identifiable, Equatable {
    enum Outcome: String, Equatable {
        case running
        case stopping
        case succeeded
        case completedWithWarnings
        case failed
        case cancelled

        var badgeLabel: String {
            switch self {
            case .running: return "Running"
            case .stopping: return "Stopping…"
            case .succeeded: return "Succeeded"
            case .completedWithWarnings: return "Completed with Warnings"
            case .failed: return "Failed"
            case .cancelled: return "Stopped"
            }
        }
    }

    let id: UUID
    let title: String
    let startedAt: Date
    var finishedAt: Date?
    let selectedAppPath: String
    var outcome: Outcome
    var steps: [AppViewModel.StepResult]
    /// Non-nil ONLY when Step 3 (`backup`) created a verified managed backup during THIS run.
    var createdBackupPath: String?
    var failureMessage: String?
    var failedStepID: String?

    var formattedDuration: String? {
        guard let finishedAt else { return nil }
        let elapsed = max(0, finishedAt.timeIntervalSince(startedAt))
        return String(format: "%.1fs", elapsed)
    }
}

/// Monotonically sequenced log entry so `Follow latest` works reliably past the 5,000-entry cap.
struct LogEntry: Identifiable, Equatable {
    let sequence: UInt64
    let timestamp: String
    let message: String

    var id: UInt64 { sequence }
    var formattedLine: String { "[\(timestamp)] \(message)" }
    var line: String { formattedLine }
}

/// Frozen diagnostic report draft captured when the Bug Report sheet opens.
struct ReportDraft: Identifiable, Equatable {
    static let maxAttachmentBytes = 1_048_576
    static let maxDescriptionCharacters = 4_000

    let id: UUID
    let createdAt: Date
    let title: String
    let appVersion: String
    let selectedAppPath: String
    let systemInfo: String
    let readinessSummary: String
    let runSummary: String
    let diagnosticsFileName: String
    let fullDiagnosticsContent: String
    let attachmentContent: String
    let attachmentData: Data
    let originalByteCount: Int
    let wasTruncated: Bool

    static func truncateDiagnosticsUTF8(_ content: String, maxBytes: Int = maxAttachmentBytes) -> (text: String, data: Data, originalBytes: Int, wasTruncated: Bool) {
        let fullData = Data(content.utf8)
        let originalBytes = fullData.count
        guard originalBytes > maxBytes else {
            return (content, fullData, originalBytes, false)
        }

        let footer = "\n\n[Truncated to fit \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)) attachment limit (original size: \(originalBytes) bytes).]"
        let footerData = Data(footer.utf8)
        let budget = max(0, maxBytes - footerData.count)

        // Walk back at most 3 bytes from budget to land on a valid UTF-8 code point boundary.
        var prefixLength = min(budget, fullData.count)
        var prefixText = ""
        while prefixLength > 0 {
            if let decoded = String(data: fullData.prefix(prefixLength), encoding: .utf8) {
                prefixText = decoded
                break
            }
            prefixLength -= 1
        }

        let combinedText = prefixText + footer
        let combinedData = Data(combinedText.utf8)
        return (combinedText, combinedData, originalBytes, true)
    }
}

@MainActor
enum WorkflowResultFormatter {
    static func summary(for results: [AppViewModel.StepResult]) -> String {
        let executedResults = results.filter { $0.outcome != .unstarted }
        let allSucceeded = !executedResults.isEmpty && results.allSatisfy { $0.outcome == .success }
        let issueSteps = results.filter { $0.outcome != .success && $0.outcome != .unstarted }.map(\.name)
        let summaryParts = results.map { step in
            "[\(step.outcome.label)] \(step.name)\(step.detail.map { ": \($0.prefix(80))" } ?? "")"
        }

        let header = allSucceeded
            ? "All steps completed successfully."
            : "Completed with attention needed: \(issueSteps.joined(separator: ", "))"
        return header + "\n" + summaryParts.joined(separator: "\n")
    }
}
