import Foundation
import Testing
@testable import _132Fixer

/// Records every script the view model runs and fails the ones it is told to.
actor ScriptRecorder {
    private(set) var scripts: [String] = []
    private let failWhen: @Sendable (String) -> Bool

    init(failWhen: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.failWhen = failWhen
    }

    func run(_ script: String) throws -> String {
        scripts.append(script)
        if failWhen(script) {
            throw AppError.processFailed(exitCode: 1, message: "fixture failure")
        }
        return "ok"
    }
}

private func isSandboxCheck(_ script: String) -> Bool { script.contains("1132fixer.zoom-sandbox-check") }
private func isClose(_ script: String) -> Bool { script == ShellCommands.stopZoom }
private func isReset(_ script: String) -> Bool { script.contains("Reset Zoom data:") }
private func isLaunch(_ script: String) -> Bool { script.contains("Launch mode: persistentSandbox") }

@Suite("AppViewModel actions")
@MainActor
struct AppViewModelWorkflowTests {
    private func makeModel(
        recorder: ScriptRecorder,
        verifyFails: Bool = false,
        home: String = FileManager.default.temporaryDirectory.path
    ) -> AppViewModel {
        AppViewModel(
            runScript: { script, _ in try await recorder.run(script) },
            verifyZoom: { appPath in
                if verifyFails { throw AppError.general("not Zoom") }
                // Any existing executable: the launch script only builds its sandbox
                // branch when the binary is present.
                return .init(appPath: appPath, binaryPath: "/bin/ls")
            },
            checkMediaAccess: { "Camera access granted; Microphone access granted" },
            homeDirectoryProvider: { home },
            appPathProvider: { "/Applications/zoom.us.app" }
        )
    }

    @Test func resetRunsChecksThenCloseWipeAndLaunchInOrder() async throws {
        let recorder = ScriptRecorder()
        let model = makeModel(recorder: recorder)
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        guard case .succeeded = model.status else {
            Issue.record("expected success, got \(model.status)")
            return
        }
        let scripts = await recorder.scripts
        let check = try #require(scripts.firstIndex(where: isSandboxCheck))
        let close = try #require(scripts.firstIndex(where: isClose))
        let reset = try #require(scripts.firstIndex(where: isReset))
        let launch = try #require(scripts.firstIndex(where: isLaunch))
        #expect(check < close && close < reset && reset < launch)
    }

    @Test func launchOnlyNeverWipesZoomData() async throws {
        let recorder = ScriptRecorder()
        let model = makeModel(recorder: recorder)
        model.launchZoom()
        await model.waitUntilFinished()

        let scripts = await recorder.scripts
        #expect(scripts.contains(where: isSandboxCheck))
        #expect(scripts.contains(where: isLaunch))
        #expect(!scripts.contains(where: isReset))
    }

    @Test func failedResetNeverLaunches() async throws {
        let recorder = ScriptRecorder(failWhen: { $0.contains("Reset Zoom data:") })
        let model = makeModel(recorder: recorder)
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        guard case .failed(let message) = model.status else {
            Issue.record("expected failure, got \(model.status)")
            return
        }
        #expect(message.contains("Zoom was not launched"))
        #expect(!(await recorder.scripts).contains(where: isLaunch))
    }

    @Test func rejectedSandboxProfileStopsBeforeAnythingIsClosedOrDeleted() async throws {
        let recorder = ScriptRecorder(failWhen: { $0.contains("1132fixer.zoom-sandbox-check") })
        let model = makeModel(recorder: recorder)
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        let scripts = await recorder.scripts
        #expect(!scripts.contains(where: isClose))
        #expect(!scripts.contains(where: isReset))
        #expect(!scripts.contains(where: isLaunch))
    }

    @Test func unverifiedZoomRunsNothing() async throws {
        let recorder = ScriptRecorder()
        let model = makeModel(recorder: recorder, verifyFails: true)
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        guard case .failed = model.status else {
            Issue.record("expected failure, got \(model.status)")
            return
        }
        #expect((await recorder.scripts).isEmpty)
    }

    @Test func unsafeHomeDirectoryRunsNothing() async throws {
        let recorder = ScriptRecorder()
        let model = makeModel(recorder: recorder, home: "/")
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        guard case .failed = model.status else {
            Issue.record("expected failure, got \(model.status)")
            return
        }
        #expect((await recorder.scripts).isEmpty)
    }

    @Test func noScriptEverRequestsAdministratorRights() async throws {
        let recorder = ScriptRecorder()
        let model = makeModel(recorder: recorder)
        model.resetAndLaunchZoom()
        await model.waitUntilFinished()

        for script in await recorder.scripts {
            #expect(!script.contains("osascript"))
            #expect(!script.contains("administrator privileges"))
            #expect(!script.contains("sudo"))
        }
    }
}
