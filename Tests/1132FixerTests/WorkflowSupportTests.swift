import Foundation
import Testing
@testable import _132Fixer

@Suite("Workflow run ownership")
struct WorkflowRunGateTests {
    @Test func rejectsOverlapAndIgnoresStaleCompletion() throws {
        var gate = WorkflowRunGate()
        let firstCandidate = gate.begin()
        let first = try #require(firstCandidate)

        #expect(gate.isActive)
        let overlappingRun = gate.begin()
        #expect(overlappingRun == nil)
        let staleCompletion = gate.finish(UUID())
        #expect(!staleCompletion)
        #expect(gate.isActive)
        let activeCompletion = gate.finish(first)
        #expect(activeCompletion)
        #expect(!gate.isActive)
        let secondRun = gate.begin()
        #expect(secondRun != nil)
    }
}

@Suite("Workflow results")
@MainActor
struct WorkflowResultFormatterTests {
    @Test func summaryDoesNotDescribeSkippedOrWarningStepsAsSuccess() {
        let results = [
            AppViewModel.StepResult(id: "safety", name: "Safety Check", outcome: .success),
            AppViewModel.StepResult(id: "network", name: "Network Check", outcome: .skipped, detail: "Unsupported"),
            AppViewModel.StepResult(id: "dns", name: "DNS Flush", outcome: .warning, detail: "Authorization canceled"),
        ]

        let summary = WorkflowResultFormatter.summary(for: results)

        #expect(summary.contains("Completed with attention needed: Network Check, DNS Flush"))
        #expect(summary.contains("[SKIP] Network Check"))
        #expect(summary.contains("[WARN] DNS Flush"))
        #expect(!summary.contains("All steps completed successfully"))
    }

    @Test func outcomeLabelsRemainDistinct() {
        #expect(AppViewModel.StepResult.Outcome.success.label == "OK")
        #expect(AppViewModel.StepResult.Outcome.warning.label == "WARN")
        #expect(AppViewModel.StepResult.Outcome.skipped.label == "SKIP")
        #expect(AppViewModel.StepResult.Outcome.failed.label == "FAIL")
    }

    @Test func startRequiresReadyNonblockingPreflight() {
        let viewModel = AppViewModel()
        #expect(!viewModel.canStartZoom)

        viewModel.preflight = .init(status: .ready, checks: [
            .init(id: "warning", label: "Network Identity", value: "Unavailable", isWarning: true),
        ])
        #expect(viewModel.canStartZoom)

        viewModel.preflight = .init(status: .ready, checks: [
            .init(id: "zoom", label: "Zoom App", value: "Invalid signature", isWarning: true, isBlocking: true),
        ])
        #expect(!viewModel.canStartZoom)
    }
}
