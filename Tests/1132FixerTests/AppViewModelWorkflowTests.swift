import Foundation
import Testing
@testable import _132Fixer

@MainActor
func isolatedPrivilegedGuard() -> PrivilegedOperationGuard {
    PrivilegedOperationGuard(defaults: UserDefaults(suiteName: "1132-tests-" + UUID().uuidString)!, bootIdentifier: "test-boot",
        ownershipLock: WorkflowOwnershipLock(directory: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("1132-lock-tests-" + UUID().uuidString)))
}

@Suite("AppViewModel workflow")
@MainActor
struct AppViewModelWorkflowTests {
    @Test func activityLogRetainsOnlyABoundedRecentWindow() {
        let model = makeViewModel(executor: WorkflowProcessFake())
        for index in 0..<3_000 { model.logMessage("\(index):" + String(repeating: "x", count: 1_024)) }
        #expect(model.logs.count <= 2_000)
        #expect(model.logs.reduce(0) { $0 + $1.utf8.count } <= 512 * 1_024)
        #expect(model.logs.last?.contains("2999:") == true)
    }

    @Test func workflowKeepsSafetyChecksBeforeDestructiveSteps() async throws {
        let executor = WorkflowProcessFake()
        let model = makeViewModel(executor: executor)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.workflowState == .completedWithWarnings)
        let commands = await executor.recordedCommands()
        let safety = try #require(commands.firstIndex { $0.contains("1132fixer.zoom-sandbox-check") })
        let close = try #require(commands.firstIndex { $0 == ShellCommands.stopZoom })
        let backup = try #require(commands.firstIndex { $0.contains(".incomplete.XXXXXX") })
        let reset = try #require(commands.firstIndex { $0.contains("__1132_RESET_STATUS__") })
        let launch = try #require(commands.firstIndex { $0.contains("Launch mode: persistentSandbox") })
        #expect(safety < close && close < backup && backup < reset && reset < launch)
    }

    @Test(arguments: ["", "__1132_RESET_STATUS__=1", "__1132_RESET_STATUS__=oops", "__1132_RESET_STATUS__=0\n__1132_RESET_STATUS__=1", "__1132_RESET_STATUS__=0\n__1132_RESET_STATUS__=0"])
    func unsuccessfulResetNeverLaunches(output: String) async throws {
        let executor = WorkflowProcessFake(resetOutput: output)
        let model = makeViewModel(executor: executor, osMajor: 13)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .failed)
        #expect(model.currentRunRecord?.failedStepID == "resetData")
        #expect(model.currentRunRecord?.createdBackupPath != nil)
        #expect(model.currentRunRecord?.steps.first { $0.id == "dns" }?.outcome == .success)
        #expect(model.lastRunResults?.first { $0.id == "resetData" }?.outcome == .failed)
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains("Launch mode: persistentSandbox") })
    }

    @Test func resetExceptionStopsBeforeLaunch() async throws {
        let executor = WorkflowProcessFake(failReset: true)
        let model = makeViewModel(executor: executor)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .failed)
        #expect(model.workflowProgress?.steps.first { $0.id == "launch" }?.state == .unstarted)
    }

    @Test func failedZoomShutdownStopsBeforeBackupOrReset() async throws {
        let executor = WorkflowProcessFake(closeBehavior: .fail)
        let model = makeViewModel(executor: executor)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .failed)
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains(".incomplete.XXXXXX") || $0.contains("__1132_RESET_STATUS__") })
    }

    @Test func cancellationRemainsSingleFlightUntilCommandUnwinds() async throws {
        let executor = WorkflowProcessFake(closeBehavior: .waitForCancellation)
        let model = makeViewModel(executor: executor)
        model.startZoom()
        try await waitForStart(executor, privileged: false)
        model.cancelWorkflow()
        #expect(model.isRunning && model.workflowState == .canceling)
        try await waitForCompletion(model)
        #expect(model.workflowState == .canceled)
        #expect(model.currentRunRecord?.outcome == .cancelled)
    }

    @Test(arguments: [WorkflowProcessFake.PrivilegedBehavior.timeout, .missingCompletion])
    func indeterminatePrivilegesBlockResetLaunchAndNewRuns(behavior: WorkflowProcessFake.PrivilegedBehavior) async throws {
        let executor = WorkflowProcessFake(privilegedBehavior: behavior)
        let model = makeViewModel(executor: executor, osMajor: 13)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.privilegedOperationNeedsSettlement)
        #expect(model.isOperationGateActive && !model.canStartZoom)
        #expect(model.currentRunRecord?.outcome == .failed)
        model.launchZoomOnly()
        model.startZoom()
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains("__1132_RESET_STATUS__") || $0.contains("Launch mode: persistentSandbox") })
        let timeouts = await executor.privilegedTimeouts()
        #expect(timeouts == [PrivilegedTimeoutPolicy.network.processTimeout])
    }

    @Test func dnsFallbackUsesItsPolicyAndStopsLaunchWhenIndeterminate() async throws {
        let executor = WorkflowProcessFake(privilegedBehavior: .timeout)
        let model = makeViewModel(executor: executor, osMajor: 15)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.privilegedOperationNeedsSettlement)
        #expect(model.currentRunRecord?.outcome == .failed)
        #expect(model.lastRunResults?.first { $0.id == "resetData" }?.outcome == .success)
        #expect(model.lastRunResults?.first { $0.id == "launch" }?.outcome == .unstarted)
        #expect(await executor.privilegedTimeouts() == [PrivilegedTimeoutPolicy.dns.processTimeout])
    }

    @Test func ordinaryCancellationAwaitsPrivilegedCompletionAndRecordsDNS() async throws {
        let executor = WorkflowProcessFake(privilegedBehavior: .delayed)
        let model = makeViewModel(executor: executor, osMajor: 13)
        model.startZoom()
        try await waitForStart(executor, privileged: true)
        model.cancelWorkflow()
        #expect(model.isRunning && model.isExecutingPrivilegedStep)
        try await waitForCompletion(model)
        #expect(!model.privilegedOperationNeedsSettlement)
        #expect(model.currentRunRecord?.outcome == .cancelled)
        #expect(model.currentRunRecord?.steps.first { $0.id == "dns" }?.outcome == .success)
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains("__1132_RESET_STATUS__") })
        #expect(await executor.privilegedTimeouts() == [PrivilegedTimeoutPolicy.network.processTimeout])
    }

    @Test func cancelledAuthorizationDoesNotResetOrLaunch() async throws {
        let executor = WorkflowProcessFake(privilegedBehavior: .cancelled)
        let model = makeViewModel(executor: executor, osMajor: 13)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .cancelled)
        #expect(!model.privilegedOperationNeedsSettlement)
        #expect(!model.lastRunResults!.contains { $0.id == "resetData" && $0.outcome == .success })
    }

    @Test func missingMutationMarkerCannotReportNetworkSuccess() async throws {
        let executor = WorkflowProcessFake(privilegedBehavior: .missingMutation)
        let model = makeViewModel(executor: executor, osMajor: 13)
        model.startZoom()
        try await waitForCompletion(model)
        #expect(model.lastRunResults?.first { $0.id == "network" }?.outcome == .warning)
        #expect(model.currentRunRecord?.outcome == .completedWithWarnings)
    }

    @Test func failedPreviewValidationProducesFailedTerminalRecord() async throws {
        let executor = WorkflowProcessFake(failSafety: true)
        let model = makeViewModel(executor: executor)
        model.dryRun()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .failed)
        #expect(model.currentRunRecord?.failedStepID == "validate")
        guard case .failed = model.workflowState else { Issue.record("Failed preview became successful"); return }
        #expect(model.lastRunResults?.first { $0.id == "network" } != nil)
    }

    @Test func sandboxOnlyLaunchNeverRequestsDestructiveOrPrivilegedWork() async throws {
        let executor = WorkflowProcessFake()
        let model = makeViewModel(executor: executor)
        model.launchZoomOnly()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .succeeded)
        #expect(model.currentRunRecord?.createdBackupPath == nil)
        let commands = await executor.recordedCommands()
        #expect(!commands.contains { $0.contains(".incomplete.XXXXXX") || $0.contains("__1132_RESET_STATUS__") || $0.contains("with administrator privileges") })
        #expect(commands.contains { $0.contains("sandbox-exec -f") && $0.contains("BJ4HAAB9B3") })
        #expect(await executor.privilegedTimeouts().isEmpty)
    }

    @Test func quickLaunchFailsBeforeShutdownWhenHomeIsInvalid() async throws {
        let executor = WorkflowProcessFake()
        let model = makeViewModel(executor: executor, home: "/")
        model.launchZoomOnly()
        try await waitForCompletion(model)
        #expect(model.currentRunRecord?.outcome == .failed)
        #expect(await executor.recordedCommands().isEmpty)
    }

    @Test func preexistingSecondModelCannotBypassIndeterminateSettlement() async throws {
        let name = "1132-shared-settlement-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstGuard = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "same-boot", ownershipLock: WorkflowOwnershipLock(directory: directory))
        let secondGuard = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "same-boot", ownershipLock: WorkflowOwnershipLock(directory: directory))
        let first = makeViewModel(executor: WorkflowProcessFake(privilegedBehavior: .timeout), osMajor: 13, operationGuard: firstGuard)
        let secondExecutor = WorkflowProcessFake()
        let second = makeViewModel(executor: secondExecutor, operationGuard: secondGuard)
        #expect(first.canStartZoom && second.canStartZoom)
        first.startZoom()
        try await waitForCompletion(first)
        #expect(second.isOperationGateActive && !second.canStartZoom)
        second.launchZoomOnly()
        second.startZoom()
        #expect(await secondExecutor.recordedCommands().isEmpty)
    }

    @Test func separateModelsCannotOverlapBeforeAdministratorWork() async throws {
        let name = "1132-shared-lock-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(name)
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
        let firstGuard = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "same-boot", ownershipLock: WorkflowOwnershipLock(directory: directory))
        let secondGuard = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "same-boot", ownershipLock: WorkflowOwnershipLock(directory: directory))
        let firstExecutor = WorkflowProcessFake(closeBehavior: .waitForCancellation)
        let secondExecutor = WorkflowProcessFake()
        let first = makeViewModel(executor: firstExecutor, operationGuard: firstGuard)
        let second = makeViewModel(executor: secondExecutor, operationGuard: secondGuard)
        first.startZoom()
        try await waitForStart(firstExecutor, privileged: false)
        second.launchZoomOnly()
        #expect(second.currentRunRecord?.outcome == .failed)
        #expect(await secondExecutor.recordedCommands().isEmpty)
        first.cancelWorkflow()
        try await waitForCompletion(first)
    }

    private func makeViewModel(executor: WorkflowProcessFake, osMajor: Int = 15, home: String = FileManager.default.temporaryDirectory.path, operationGuard: PrivilegedOperationGuard? = nil) -> AppViewModel {
        let model = AppViewModel(initialDiskBackupPath: nil, processExecutor: executor,
            zoomVerifier: { _ in .init(appPath: "/Applications/zoom.us.app", binaryPath: "/usr/bin/true") },
            mediaAccessChecker: { "Explicit fixture media grants" }, homeDirectoryProvider: { home },
            privilegedGuard: operationGuard ?? isolatedPrivilegedGuard(),
            networkEnvironment: { .init(osMajor: osMajor, hardware: .appleSilicon, executionArchitecture: "arm64") },
            backupVerifier: { _, _ in true }, refreshPreflightAfterRun: false)
        model.preflight = .init(status: .ready, checks: [])
        return model
    }

    private func waitForCompletion(_ model: AppViewModel) async throws {
        for _ in 0..<500 {
            if !model.isRunning { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.general("Timed out waiting for workflow")
    }

    private func waitForStart(_ executor: WorkflowProcessFake, privileged: Bool) async throws {
        for _ in 0..<500 {
            if await executor.hasStarted(privileged: privileged) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.general("Timed out waiting for fixture command")
    }
}

actor WorkflowProcessFake: ProcessExecuting {
    enum CloseBehavior: Equatable { case succeed, fail, waitForCancellation }
    enum PrivilegedBehavior: Equatable, Sendable { case succeed, delayed, timeout, missingCompletion, missingMutation, cancelled }
    private let closeBehavior: CloseBehavior
    private let resetOutput: String
    private let failReset: Bool
    private let failSafety: Bool
    private let privilegedBehavior: PrivilegedBehavior
    private var commands: [String] = []
    private var timeouts: [TimeInterval] = []
    private var closeStarted = false
    private var privilegedStarted = false

    init(closeBehavior: CloseBehavior = .succeed, resetOutput: String = "__1132_RESET_STATUS__=0", failReset: Bool = false,
         failSafety: Bool = false, privilegedBehavior: PrivilegedBehavior = .succeed) {
        self.closeBehavior = closeBehavior
        self.resetOutput = resetOutput
        self.failReset = failReset
        self.failSafety = failSafety
        self.privilegedBehavior = privilegedBehavior
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval, maxOutputBytes: Int) async throws -> ProcessExecutionResult {
        let command = arguments.last ?? ""
        commands.append(command)
        if executable == ShellCommands.osascriptPath {
            privilegedStarted = true
            timeouts.append(timeout)
            if privilegedBehavior == .timeout { throw ProcessExecutionError.timedOut(seconds: Int(timeout)) }
            if privilegedBehavior == .cancelled { return result("__1132_AUTH_CANCELLED__=0") }
            if privilegedBehavior == .delayed { try await Task.sleep(nanoseconds: 300_000_000) }
            guard let encoded = command.components(separatedBy: "/bin/echo '").dropFirst().first?.components(separatedBy: "'").first,
                  let data = Data(base64Encoded: encoded), let script = String(data: data, encoding: .utf8) else {
                throw AppError.general("Fixture received an unrecognized privileged command")
            }
            var output = script.contains("__1132_DNS_STATUS__") ? "__1132_DNS_STATUS__=0\n" : ""
            if script.contains("__1132_SPOOF_STATUS__") && privilegedBehavior != .missingMutation { output += "__1132_SPOOF_STATUS__=0\n" }
            if privilegedBehavior != .missingCompletion { output += "__1132_PRIVILEGED_COMPLETE__=0" }
            return result(output)
        }
        if command == ShellCommands.stopZoom {
            closeStarted = true
            if closeBehavior == .fail { return result("Zoom still running", exitCode: 1) }
            if closeBehavior == .waitForCancellation { try await Task.sleep(nanoseconds: 10_000_000_000) }
            return result("Zoom stopped")
        }
        if command.contains("1132fixer.zoom-sandbox-check") { return result("Profile validated", exitCode: failSafety ? 1 : 0) }
        if command.contains(".incomplete.XXXXXX") { return result("/fixture/Library/Application Support/1132Fixer/Backups/snapshot-test") }
        if command.contains("__1132_RESET_STATUS__") {
            if failReset { throw AppError.general("Injected reset failure") }
            return result(resetOutput)
        }
        if command == "/sbin/route -n get default" || command == "/sbin/route -n get default 2>/dev/null" { return result("interface: en0") }
        if command == "/usr/sbin/networksetup -listallhardwareports" { return result("Hardware Port: Wi-Fi\nDevice: en0") }
        if command == "/usr/sbin/networksetup -listnetworkserviceorder" { return result("(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)") }
        if command == ShellCommands.makeVerifyMACCommand(device: "en0") { return result("02:ab:cd:ef:12:34") }
        if command.contains("Network did not become ready") { return result("Network ready on en0") }
        if command == ShellCommands.stopZoomUpdaters { return result("Updaters stopped") }
        if command.contains("Launch mode: persistentSandbox") { return result("Tracked sandbox child remained active") }
        if command == ShellCommands.makeZoomRunningCheckCommand() { return result("stopped") }
        return result("Unexpected fixture command", exitCode: 1)
    }

    func recordedCommands() -> [String] { commands }
    func privilegedTimeouts() -> [TimeInterval] { timeouts }
    func hasStarted(privileged: Bool) -> Bool { privileged ? privilegedStarted : closeStarted }
    private func result(_ output: String = "", exitCode: Int32 = 0) -> ProcessExecutionResult {
        .init(exitCode: exitCode, standardOutput: output, standardError: "", outputWasTruncated: false)
    }
}
