import Testing
@testable import _132Fixer

struct WorkspaceLayoutTests {
    @Test func idleIsReady() {
        #expect(WorkspaceStage(workflowState: .idle, isRunning: false) == .ready)
    }

    @Test func activeStatesAreRunning() {
        let active: [AppViewModel.WorkflowState] = [
            .preflight, .closingZoom, .spoofingMAC, .checkingNetwork, .backingUpState,
            .clearingState, .flushingDNS, .stoppingUpdaters, .checkingMediaAccess, .launchingZoom, .canceling,
        ]
        for state in active {
            #expect(WorkspaceStage(workflowState: state, isRunning: false) == .running, "\(state)")
        }
        #expect(WorkspaceStage(workflowState: .idle, isRunning: true) == .running)
    }

    @Test func finishedStatesAreResults() {
        let finished: [AppViewModel.WorkflowState] = [.completed, .completedWithWarnings, .failed("x"), .canceled]
        for state in finished {
            #expect(WorkspaceStage(workflowState: state, isRunning: false) == .results, "\(state)")
        }
    }

    @Test func progressCountsFinishedStepsAndNamesCurrentStep() {
        let summary = RunProgressSummary(states: [
            (name: "Close Zoom", state: .succeeded),
            (name: "Network identity", state: .skipped),
            (name: "Clear state", state: .running),
            (name: "Launch", state: .unstarted),
        ])
        #expect(summary.finishedCount == 2)
        #expect(summary.totalCount == 4)
        #expect(summary.fraction == 0.5)
        #expect(summary.label == "Step 3 of 4 · Clear state")
    }

    @Test func stepNumberUsesTheRunningStepPosition() {
        let summary = RunProgressSummary(states: [
            (name: "Validate", state: .succeeded),
            (name: "Close Zoom", state: .unstarted),
            (name: "Backup", state: .running),
        ])
        #expect(summary.currentStepNumber == 3)
        #expect(summary.label == "Step 3 of 3 · Backup")
    }

    @Test func sidebarLeavesRoomForTheFourColumnRecordAtDefaultWidth() {
        let contentWidth = Theme.Window.defaultWidth - Theme.Window.sidebarWidth - 1 - Theme.Spacing.outerPadding * 2
        #expect(Theme.Window.defaultWidth >= Theme.Window.sidebarBreakpoint)
        #expect(contentWidth >= Theme.Window.recordFourColumnMinWidth)
    }

    @Test func emptyProgressIsSafe() {
        let summary = RunProgressSummary(states: [])
        #expect(summary.fraction == 0)
        #expect(summary.label == "Preparing steps…")
    }
}
