import Foundation
import Testing
@testable import _132Fixer

/// Closing Zoom must only ever touch this user's processes named exactly like Zoom's.
@Suite("Stop Zoom")
struct StopZoomTests {
    @Test func processSelectorsAreScopedToThisUserAndLiteralNames() {
        #expect(ShellCommands.currentUserProcessArguments(name: "zoom.us").contains("-u"))
        let pattern = "^" + ShellCommands.currentUserProcessArguments(name: "zoom.us").last! + "$"
        #expect("zoom.us".range(of: pattern, options: .regularExpression) != nil)
        #expect("zoomXus".range(of: pattern, options: .regularExpression) == nil)
        #expect(ShellCommands.stopZoom.contains("zoom[.]us"))
        #expect(ShellCommands.stopZoom.contains("pgrep -u \"$uid\" -x"))
        let launch = ShellCommands.makeLaunchZoomCommand(zoomBinaryPath: "/Applications/zoom.us.app/Contents/Helpers/zoom-real", zoomBinaryExists: true, homeDirectory: "/Users/fixture", verifiedAppPath: "/Applications/zoom.us.app")
        #expect(launch.contains("zoom_app='/Applications/zoom.us.app'"))
        #expect(launch.contains("jobs -pr"))
        #expect(launch.contains("Launch provenance: unknown"))
        #expect(!launch.contains("wait_for_sandboxed_zoom_stability"))
    }

    @Test func literalZoomProbeDoesNotMatchSimilarlyNamedDisposableProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("1132-name-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("zoomXus")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let result = try await BoundedProcessExecutor().run(executable: "/usr/bin/pgrep",
            arguments: ShellCommands.currentUserProcessArguments(name: "zoom.us"), timeout: 3)
        #expect(!result.standardOutput.components(separatedBy: .newlines).contains(String(process.processIdentifier)))
    }

    /// Runs the real shutdown script against real BSD pgrep/pkill. It signals this user's
    /// processes named exactly zoom.us, so it runs only on disposable CI runners. The
    /// decoys are launched detached, like real Zoom, so no unreaped child of the test
    /// process lingers as a zombie that pgrep could still match.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
                   "Kills this user's zoom.us processes; runs only on CI runners"))
    func stopZoomStopsOnlyTheLiteralZoomNameOnDarwin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("1132-stop-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pids: [pid_t] = []
        defer {
            for pid in pids { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        func launchDetached(_ name: String) async throws -> pid_t {
            let executable = directory.appendingPathComponent(name)
            let pidFile = directory.appendingPathComponent(name + ".pid")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
            // No pipes: the detached decoy must not hold any descriptor the test waits on.
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
            launcher.arguments = ["-c", #""$0" 20 </dev/null >/dev/null 2>&1 & echo "$!" > "$1""#, executable.path, pidFile.path]
            launcher.standardInput = FileHandle.nullDevice
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()
            // Poll for the complete PID line rather than waiting on the launcher shell.
            var raw = ""
            let deadline = Date().addingTimeInterval(5)
            while !raw.hasSuffix("\n") && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                raw = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
            }
            let pid = try #require(pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), "decoy \(name) did not report its PID")
            pids.append(pid)
            return pid
        }
        func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
        let zoom = try await launchDetached("zoom.us")
        let lookalike = try await launchDetached("zoomXus")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(isAlive(zoom) && isAlive(lookalike))

        let result = try await BoundedProcessExecutor().run(executable: "/bin/bash",
            arguments: ["-c", ShellCommands.stopZoom], timeout: 30)
        #expect(result.exitCode == 0, "stopZoom failed: \(result.combinedOutput)")
        #expect(result.standardOutput.contains("Zoom was running and has been closed."))
        let deadline = Date().addingTimeInterval(5)
        while isAlive(zoom) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!isAlive(zoom))
        #expect(isAlive(lookalike))
    }
}
