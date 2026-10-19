import Foundation
import Testing
@testable import _132Fixer

@Suite("BoundedProcessExecutor")
struct ProcessExecutorTests {
    private let executor = BoundedProcessExecutor()

    @Test func capturesStandardOutputAndError() async throws {
        let result = try await executor.run(
            executable: "/bin/bash",
            arguments: ["-c", "printf out; printf err >&2"],
            timeout: 2,
            maxOutputBytes: 1_024
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput == "out")
        #expect(result.standardError == "err")
        #expect(!result.outputWasTruncated)
    }

    @Test func reportsNonZeroExitWithoutDiscardingOutput() async throws {
        let result = try await executor.run(
            executable: "/bin/bash",
            arguments: ["-c", "printf failure >&2; exit 7"],
            timeout: 2,
            maxOutputBytes: 1_024
        )

        #expect(result.exitCode == 7)
        #expect(result.standardError == "failure")
    }

    @Test func capsRetainedOutputAndKeepsTheTail() async throws {
        let result = try await executor.run(
            executable: "/bin/bash",
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -n 100000; printf newest"],
            timeout: 3,
            maxOutputBytes: 2_048
        )

        #expect(result.exitCode == 0)
        #expect(result.outputWasTruncated)
        #expect(result.standardOutput.hasSuffix("newest"))
        #expect(result.standardOutput.utf8.count <= 1_024)
    }

    @Test func timesOutAndTerminatesTheCommand() async {
        do {
            _ = try await executor.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                timeout: 0.1,
                maxOutputBytes: 1_024
            )
            Issue.record("Expected a timeout")
        } catch let error as ProcessExecutionError {
            #expect(error == .timedOut(seconds: 1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cancellationTerminatesTheCommand() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let task = Task {
            try await executor.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                timeout: 5,
                maxOutputBytes: 1_024
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(4))
    }
}
