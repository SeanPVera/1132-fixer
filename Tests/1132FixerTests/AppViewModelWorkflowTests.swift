import Foundation
import Testing
@testable import _132Fixer

@Suite("AppViewModel workflow")
struct AppViewModelWorkflowTests {
    @Test
    @MainActor
    func activityLogRetainsOnlyABoundedRecentWindow() {
        let viewModel = makeViewModel(executor: WorkflowProcessFake())
        let payload = String(repeating: "x", count: 1_024)

        for index in 0..<3_000 {
            viewModel.logMessage("\(index):\(payload)")
        }

        #expect(viewModel.logs.count <= 2_000)
        #expect(viewModel.logs.reduce(0) { $0 + $1.utf8.count } <= 512 * 1_024)
        #expect(viewModel.logs.last?.contains("2999:") == true)
        #expect(viewModel.logs.first?.hasSuffix("] 0:\(payload)") == false)
    }

    @Test
    @MainActor
    func workflowKeepsSafetyChecksBeforeDestructiveSteps() async throws {
        let executor = WorkflowProcessFake()
        let viewModel = makeViewModel(executor: executor)

        viewModel.startZoom()
        try await waitForCompletion(viewModel)

        #expect(viewModel.workflowState == .completed)
        let commands = await executor.recordedCommands()
        let readiness = try #require(commands.firstIndex { $0.contains("1132fixer.zoom-sandbox-check") })
        let close = try #require(commands.firstIndex { $0 == ShellCommands.stopZoom })
        let backup = try #require(commands.firstIndex { $0.contains(".incomplete.XXXXXX") })
        let reset = try #require(commands.firstIndex { $0.contains("__1132_RESET_STATUS__") })
        let launch = try #require(commands.firstIndex { $0.contains("Launch mode: persistentSandbox") })

        #expect(readiness < close)
        #expect(close < backup)
        #expect(backup < reset)
        #expect(reset < launch)
    }

    @Test
    @MainActor
    func failedZoomShutdownStopsBeforeBackupOrReset() async throws {
        let executor = WorkflowProcessFake(closeBehavior: .fail)
        let viewModel = makeViewModel(executor: executor)

        viewModel.startZoom()
        try await waitForCompletion(viewModel)

        guard case .failed = viewModel.workflowState else {
            Issue.record("Expected workflow failure after Zoom shutdown failed")
            return
        }
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains(".incomplete.XXXXXX") })
        #expect(!commands.contains { $0.contains("__1132_RESET_STATUS__") })
        #expect(viewModel.workflowProgress?.steps.first { $0.id == "backup" }?.state == .skipped)
    }

    @Test
    @MainActor
    func cancellationRemainsSingleFlightUntilTheCommandUnwinds() async throws {
        let executor = WorkflowProcessFake(closeBehavior: .waitForCancellation)
        let viewModel = makeViewModel(executor: executor)

        viewModel.startZoom()
        try await waitForCloseToStart(executor)
        viewModel.cancelWorkflow()

        #expect(viewModel.isRunning)
        #expect(viewModel.workflowState == .canceling)

        try await waitForCompletion(viewModel)
        #expect(!viewModel.isRunning)
        #expect(viewModel.workflowState == .canceled)
    }

    @Test
    @MainActor
    func resetPreventsObsoleteZoomLocationVerificationFromApplying() async throws {
        let path = "/Applications/First/zoom.us.app"
        let verifier = DelayedZoomVerifier(delays: [path: 50_000_000])
        let viewModel = makeLocationViewModel(verifier: verifier)

        viewModel.verifyAndSelectZoomLocation(path)
        try await waitForVerification(path, toStartIn: verifier)
        viewModel.resetZoomLocation()
        try await waitForVerification(path, toCompleteIn: verifier)
        await settleAsyncWork()

        #expect(viewModel.customZoomAppPath == nil)
        #expect(!viewModel.logs.contains { $0.contains("Zoom location set to: \(path)") })
    }

    @Test
    @MainActor
    func newerZoomLocationSelectionWinsWhenOlderVerificationFinishesLast() async throws {
        let first = "/Applications/First/zoom.us.app"
        let second = "/Applications/Second/zoom.us.app"
        let verifier = DelayedZoomVerifier(delays: [
            first: 100_000_000,
            second: 10_000_000,
        ])
        let viewModel = makeLocationViewModel(verifier: verifier)

        viewModel.verifyAndSelectZoomLocation(first)
        try await waitForVerification(first, toStartIn: verifier)
        viewModel.verifyAndSelectZoomLocation(second)
        try await waitForVerification(second, toStartIn: verifier)

        try await waitForSelectedLocation(second, in: viewModel)
        try await waitForVerification(first, toCompleteIn: verifier)
        await settleAsyncWork()

        #expect(viewModel.customZoomAppPath == second)
        #expect(!viewModel.logs.contains { $0.contains("Zoom location set to: \(first)") })
    }

    @MainActor
    private func makeViewModel(executor: WorkflowProcessFake) -> AppViewModel {
        let viewModel = AppViewModel(
            processExecutor: executor,
            zoomVerifier: { _ in
                .init(
                    appPath: "/Applications/zoom.us.app",
                    // A successful verifier promises an executable path. Use a real
                    // executable so this fake exercises the persistent-sandbox branch.
                    binaryPath: "/usr/bin/true"
                )
            },
            mediaAccessChecker: { "Camera and microphone test grants" },
            homeDirectoryProvider: { FileManager.default.temporaryDirectory.path }
        )
        viewModel.preflight = .init(status: .ready, checks: [])
        return viewModel
    }

    @MainActor
    private func makeLocationViewModel(verifier: DelayedZoomVerifier) -> AppViewModel {
        AppViewModel(
            processExecutor: WorkflowProcessFake(),
            zoomVerifier: { await verifier.verify($0) },
            mediaAccessChecker: { "Camera and microphone test grants" },
            homeDirectoryProvider: { FileManager.default.temporaryDirectory.path },
            zoomLocationSetter: { _ in }
        )
    }

    @MainActor
    private func waitForCompletion(
        _ viewModel: AppViewModel,
        attempts: Int = 500
    ) async throws {
        for _ in 0..<attempts {
            if !viewModel.isRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for asynchronous workflow state")
    }

    private func waitForCloseToStart(_ executor: WorkflowProcessFake) async throws {
        for _ in 0..<500 {
            if await executor.hasStartedClose() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for the close command")
    }

    private func waitForVerification(
        _ path: String,
        toStartIn verifier: DelayedZoomVerifier,
        attempts: Int = 500
    ) async throws {
        for _ in 0..<attempts {
            if await verifier.hasStarted(path) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Zoom verification of \(path)")
    }

    private func waitForVerification(
        _ path: String,
        toCompleteIn verifier: DelayedZoomVerifier,
        attempts: Int = 500
    ) async throws {
        for _ in 0..<attempts {
            if await verifier.hasCompleted(path) { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Zoom verification to complete for \(path)")
    }

    @MainActor
    private func waitForSelectedLocation(
        _ path: String,
        in viewModel: AppViewModel,
        attempts: Int = 500
    ) async throws {
        for _ in 0..<attempts {
            if viewModel.customZoomAppPath == path { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Timed out waiting for Zoom location selection")
    }

    private func settleAsyncWork() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private actor DelayedZoomVerifier {
    private let delays: [String: UInt64]
    private var startedPaths: Set<String> = []
    private var completedPaths: Set<String> = []

    init(delays: [String: UInt64]) {
        self.delays = delays
    }

    func verify(_ path: String) async -> ZoomBundleVerifier.VerifiedBundle {
        startedPaths.insert(path)
        if let delay = delays[path] {
            // Detached delay deliberately ignores cancellation so the production
            // generation guard is exercised when an obsolete verifier returns late.
            let delayTask = Task.detached {
                try? await Task.sleep(nanoseconds: delay)
            }
            await delayTask.value
        }
        completedPaths.insert(path)
        return verifiedBundle(for: path)
    }

    func hasStarted(_ path: String) -> Bool {
        startedPaths.contains(path)
    }

    func hasCompleted(_ path: String) -> Bool {
        completedPaths.contains(path)
    }

    private func verifiedBundle(for path: String) -> ZoomBundleVerifier.VerifiedBundle {
        .init(appPath: path, binaryPath: "/usr/bin/true")
    }
}

private actor WorkflowProcessFake: ProcessExecuting {
    enum CloseBehavior {
        case succeed
        case fail
        case waitForCancellation
    }

    private let closeBehavior: CloseBehavior
    private var commands: [String] = []
    private var closeStarted = false

    init(closeBehavior: CloseBehavior = .succeed) {
        self.closeBehavior = closeBehavior
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> ProcessExecutionResult {
        let command = arguments.last ?? ""
        commands.append(command)

        if command == ShellCommands.stopZoom {
            closeStarted = true
            switch closeBehavior {
            case .succeed:
                return result("Zoom stopped")
            case .fail:
                return result("Zoom is still running", exitCode: 1)
            case .waitForCancellation:
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return result()
            }
        }

        if command == "/sbin/route -n get default" {
            return result("route to: default\ninterface: en0\n")
        }
        if command == "/usr/sbin/networksetup -listallhardwareports" {
            return result("Hardware Port: Ethernet\nDevice: en0\nEthernet Address: 00:11:22:33:44:55\n")
        }
        if command == "/usr/sbin/networksetup -listnetworkserviceorder" {
            return result("(1) Ethernet\n(Hardware Port: Ethernet, Device: en0)\n")
        }
        if command.contains(".incomplete.XXXXXX") {
            return result("/Users/test/Library/Application Support/1132Fixer/Backups/test")
        }
        if command.contains("__1132_RESET_STATUS__") {
            return result("__1132_RESET_STATUS__=0")
        }
        if executable == ShellCommands.osascriptPath {
            return result("__1132_DNS_STATUS__=0")
        }
        if command.contains("route -n get default") && command.contains("Network did not become ready") {
            return result("Network ready on en0.")
        }
        if command.contains("awk '/^[[:space:]]*ether") {
            return result("02:ab:cd:ef:12:34")
        }
        return result()
    }

    func recordedCommands() -> [String] {
        commands
    }

    func hasStartedClose() -> Bool {
        closeStarted
    }

    private func result(_ output: String = "", exitCode: Int32 = 0) -> ProcessExecutionResult {
        ProcessExecutionResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: "",
            outputWasTruncated: false
        )
    }
}
