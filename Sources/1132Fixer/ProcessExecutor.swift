import Foundation
import Darwin

struct ProcessExecutionResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool

    var combinedOutput: String {
        let output = [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard outputWasTruncated else { return output }
        return "[earlier command output truncated]\n" + output
    }
}

enum ProcessExecutionError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Could not start command: \(message)"
        case .timedOut(let seconds):
            return "Command timed out after \(seconds) seconds."
        }
    }
}

protocol ProcessExecuting: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> ProcessExecutionResult
}

/// Runs child processes without a shell, drains stdout and stderr concurrently, and
/// bounds both execution time and retained output. Cancellation signals the active
/// process tree and waits for exit (or the bounded force-kill grace period) before returning.
struct BoundedProcessExecutor: ProcessExecuting {
    static let defaultMaxOutputBytes = 512 * 1_024

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int = BoundedProcessExecutor.defaultMaxOutputBytes
    ) async throws -> ProcessExecutionResult {
        try Task.checkCancellation()

        let controller = ProcessController()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessExecutionResult, Error>) in
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                let outputLimit = max(maxOutputBytes, 1)
                let stdoutBuffer = LockedTailBuffer(limit: max(outputLimit / 2, 1))
                let stderrBuffer = LockedTailBuffer(limit: max(outputLimit - outputLimit / 2, 1))
                let completion = ContinuationGate()
                let timeoutState = TimeoutState()
                let readGroup = DispatchGroup()

                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                @Sendable func finish(_ result: Result<ProcessExecutionResult, Error>) {
                    guard completion.beginResume() else { return }
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                @Sendable func closeReadHandles() {
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                }

                @Sendable func forceStopParent() {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                controller.installCancellationFallback {
                    forceStopParent()
                    closeReadHandles()
                    finish(.failure(CancellationError()))
                }

                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + max(timeout, 0.1))
                timer.setEventHandler {
                    timeoutState.markTimedOut()
                    controller.terminateRegisteredProcess()
                    // A detached descendant can inherit a pipe even after the direct process
                    // exits. Close our read ends after the kill grace period so timeout remains
                    // a hard bound instead of waiting forever for that descendant's EOF.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                        forceStopParent()
                        closeReadHandles()
                        finish(.failure(ProcessExecutionError.timedOut(seconds: Int(timeout.rounded(.up)))))
                    }
                }
                timer.resume()

                readGroup.enter()
                readGroup.enter()

                process.terminationHandler = { terminatedProcess in
                    let status = terminatedProcess.terminationStatus
                    readGroup.notify(queue: .global(qos: .utility)) {
                        timer.cancel()
                        controller.clear(terminatedProcess)

                        if timeoutState.didTimeOut {
                            finish(.failure(ProcessExecutionError.timedOut(seconds: Int(timeout.rounded(.up)))))
                            return
                        }

                        let stdout = stdoutBuffer.snapshot()
                        let stderr = stderrBuffer.snapshot()
                        finish(.success(ProcessExecutionResult(
                            exitCode: status,
                            standardOutput: String(decoding: stdout.data, as: UTF8.self),
                            standardError: String(decoding: stderr.data, as: UTF8.self),
                            outputWasTruncated: stdout.wasTruncated || stderr.wasTruncated
                        )))
                    }
                }

                do {
                    try process.run()
                    controller.register(process)
                } catch {
                    timer.cancel()
                    readGroup.leave()
                    readGroup.leave()
                    finish(.failure(ProcessExecutionError.launchFailed(error.localizedDescription)))
                    return
                }

                for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
                    DispatchQueue.global(qos: .utility).async {
                        let handle = pipe.fileHandleForReading
                        while true {
                            do {
                                guard let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty else {
                                    break
                                }
                                buffer.append(chunk)
                            } catch {
                                break
                            }
                        }
                        readGroup.leave()
                    }
                }
            }
        } onCancel: {
            controller.cancel()
        }

        try Task.checkCancellation()
        return result
    }
}

private final class LockedTailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        if chunk.count >= limit {
            data = Data(chunk.suffix(limit))
            truncated = true
            return
        }

        let overflow = data.count + chunk.count - limit
        if overflow > 0 {
            data.removeFirst(overflow)
            truncated = true
        }
        data.append(chunk)
    }

    func snapshot() -> (data: Data, wasTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, truncated)
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return false }
        hasResumed = true
        return true
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class ProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var cancellationFallback: (@Sendable () -> Void)?
    private var cancellationFallbackScheduled = false

    func installCancellationFallback(_ fallback: @escaping @Sendable () -> Void) {
        lock.lock()
        cancellationFallback = fallback
        let shouldSchedule = cancellationRequested && !cancellationFallbackScheduled
        if shouldSchedule {
            cancellationFallbackScheduled = true
        }
        lock.unlock()

        if shouldSchedule {
            Self.scheduleFallback(fallback)
        }
    }

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancellationRequested
        lock.unlock()

        if shouldTerminate {
            Self.scheduleTermination(process)
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        let fallback = cancellationFallback
        let shouldScheduleFallback = fallback != nil && !cancellationFallbackScheduled
        if shouldScheduleFallback {
            cancellationFallbackScheduled = true
        }
        lock.unlock()

        if let process {
            Self.scheduleTermination(process)
        }
        if shouldScheduleFallback, let fallback {
            Self.scheduleFallback(fallback)
        }
    }

    func terminateRegisteredProcess() {
        lock.lock()
        let process = self.process
        lock.unlock()

        if let process {
            Self.terminateProcessTree(process)
        }
    }

    /// Stops the process and its direct children, then force-kills the parent after a
    /// short grace period. Privileged shell commands also carry their own watchdog,
    /// because an unprivileged parent cannot signal a detached root-owned descendant.
    private static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier

        let childKiller = Process()
        childKiller.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        childKiller.arguments = ["-TERM", "-P", "\(pid)"]
        childKiller.standardOutput = FileHandle.nullDevice
        childKiller.standardError = FileHandle.nullDevice
        if (try? childKiller.run()) != nil {
            childKiller.waitUntilExit()
        }

        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private static func scheduleFallback(_ fallback: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
            fallback()
        }
    }

    private static func scheduleTermination(_ process: Process) {
        DispatchQueue.global(qos: .utility).async {
            terminateProcessTree(process)
        }
    }
}
