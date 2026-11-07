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
                commandSummary: "pgrep / pkill scoped to the current UID (zoom.us, caphost, CptHost)"
            ),
            RepairStepSpec(
                index: 3,
                id: "backup",
                name: "Backup State",
                scope: "~/Library/Application Support",
                requiresAdmin: false,
                plannedSummary: "Copy the four listed Zoom state paths to a private timestamped recovery snapshot before mutation.",
                commandSummary: "cp -a to ~/\(ZoomStateScope.backupRelativeRoot)/snapshot-… (atomic publication)"
            ),
            RepairStepSpec(
                index: 4,
                id: "network",
                name: macSpoofingDisabled ? "Network Check" : "MAC Spoof & Network",
                scope: "Network & Admin",
                requiresAdmin: !macSpoofingDisabled,
                plannedSummary: macSpoofingDisabled
                    ? "Inspect the active default route. No verified automatic identity mechanism is available; manual Private Wi-Fi Address settings may be available on macOS 15+."
                    : "Attempt a legacy MAC change, reconnect the service, and flush DNS in the same administrator session. Driver support and the resulting address are checked.",
                commandSummary: macSpoofingDisabled
                    ? "route -n get default & networksetup interface/service inspection"
                    : "ifconfig lladdr & networksetup service cycle (Administrator)"
            ),
            RepairStepSpec(
                index: 5,
                id: "resetData",
                name: "Clear Local State",
                scope: "User Library",
                requiresAdmin: false,
                plannedSummary: "Clear the four backed-up state paths and permanently remove the listed local logs. Containers and keychains are not reset.",
                commandSummary: "rm on the listed state paths and log pattern; defaults delete us.zoom.xos (current user)"
            ),
            RepairStepSpec(
                index: 6,
                id: "dns",
                name: "DNS Flush",
                scope: "Administrator",
                requiresAdmin: true,
                plannedSummary: "Flush system DNS caches and send HUP to mDNSResponder. This may already run during Step 4 before the local reset.",
                commandSummary: "dscacheutil -flushcache & killall -HUP mDNSResponder (Administrator)"
            ),
            RepairStepSpec(
                index: 7,
                id: "updaters",
                name: "Stop Updaters",
                scope: "User LaunchAgents",
                requiresAdmin: false,
                plannedSummary: "Unload Zoom background updater LaunchAgents for the current login session without deleting plists.",
                commandSummary: "pkill current-UID updaters; launchctl bootout gui/$UID and user/$UID agents"
            ),
            RepairStepSpec(
                index: 8,
                id: "mediaAccess",
                name: "Camera & Mic",
                scope: "Privacy & Security",
                requiresAdmin: false,
                plannedSummary: "Request Camera and Microphone access needed by the sandboxed session. Verify Zoom media behavior after launch; Zoom may also request permissions.",
                commandSummary: "AVCaptureDevice authorization check (60s prompt timeout)"
            ),
            RepairStepSpec(
                index: 9,
                id: "launch",
                name: "Launch Zoom",
                scope: "Sandbox Exec",
                requiresAdmin: false,
                plannedSummary: "Re-verify Zoom immediately before sandbox-exec launch using your existing home and login keychain. The profile denies selected paths; it is not full isolation.",
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
                path: "~/" + ZoomStateScope.backupRelativeRoot,
                action: "New timestamped backup created in Step 3 before any deletion",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "user-zoom-data",
                label: "User Zoom State",
                path: ZoomStateScope.consentPaths,
                action: "Backed up first, then cleared in Step 5 (unprivileged)",
                requiresAdmin: false
            ),
            AffectedLocation(
                id: "user-zoom-logs",
                label: "Zoom Local Logs",
                path: "~/" + ZoomStateScope.removedLogPattern,
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
            "Sandboxed launch only: this launcher uses sandbox-exec with selected deny rules and your existing home; login keychain access remains available.",
            "Starting normal Zoom independently bypasses this launcher's protection. This app does not prove that error 1132 is resolved.",
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

/// Monotonically sequenced log entry; retention is capped at 2,000 entries and 512 KiB.
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
        let limit = max(0, maxBytes)
        guard originalBytes > limit else {
            return (content, fullData, originalBytes, false)
        }
        func prefix(_ bytes: Data, budget: Int) -> Data {
            var data = Data(bytes.prefix(max(0, budget)))
            while !data.isEmpty && String(data: data, encoding: .utf8) == nil { data.removeLast() }
            return data
        }
        let note = Data("\n[Truncated from \(originalBytes) bytes; metadata and newest activity retained.]\n".utf8)
        guard limit > note.count else {
            let data = prefix(note, budget: limit)
            return (String(decoding: data, as: UTF8.self), data, originalBytes, true)
        }
        let budget = limit - note.count
        let metadata = content.components(separatedBy: "--- Activity Log").first ?? content
        let header = prefix(Data(metadata.utf8), budget: min(65_536, budget / 3))
        var tail = Data(fullData.suffix(budget - header.count))
        while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
        let data = header + note + tail
        return (String(decoding: data, as: UTF8.self), data, originalBytes, true)
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
