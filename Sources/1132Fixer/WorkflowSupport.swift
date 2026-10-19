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

/// Tracks the newest request in a replaceable asynchronous operation. Starting a
/// request invalidates every older token, even when the underlying work ignores
/// cancellation and completes later.
struct LatestRequestGate {
    private(set) var activeRequestID: UUID?

    mutating func begin() -> UUID {
        let requestID = UUID()
        activeRequestID = requestID
        return requestID
    }

    mutating func finish(_ requestID: UUID) -> Bool {
        guard activeRequestID == requestID else { return false }
        activeRequestID = nil
        return true
    }

    mutating func invalidate() {
        activeRequestID = nil
    }
}

@MainActor
enum WorkflowResultFormatter {
    static func summary(for results: [AppViewModel.StepResult]) -> String {
        let allSucceeded = results.allSatisfy { $0.outcome == .success }
        let issueSteps = results.filter { $0.outcome != .success }.map(\.name)
        let summaryParts = results.map { step in
            "[\(step.outcome.label)] \(step.name)\(step.detail.map { ": \($0.prefix(80))" } ?? "")"
        }

        let header = allSucceeded
            ? "All steps completed successfully."
            : "Completed with attention needed: \(issueSteps.joined(separator: ", "))"
        return header + "\n" + summaryParts.joined(separator: "\n")
    }
}
