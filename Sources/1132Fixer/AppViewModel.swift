import AVFoundation
import AppKit
import Combine
import Foundation

/// Runs the app's two actions:
///
/// - **Launch Zoom**: verify Zoom and the sandbox profile, then launch Zoom inside
///   `sandbox-exec` (the launch script closes any running Zoom first).
/// - **Reset & Launch**: the same checks, then close Zoom, wipe its local state, and launch.
///
/// Nothing here needs administrator rights. Zoom is only ever launched in sandbox mode;
/// there is no fallback to a normal launch.
@MainActor
final class AppViewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String)
    }

    /// Runs a script through `/bin/bash -c` and returns its combined output; throws on a
    /// non-zero exit. Tests replace it; the app uses `BoundedProcessExecutor`.
    typealias ScriptRunner = (_ script: String, _ timeout: TimeInterval) async throws -> String
    typealias ZoomVerifier = (_ appPath: String) async throws -> ZoomBundleVerifier.VerifiedBundle
    typealias MediaAccessChecker = () async throws -> String

    static let mediaAccessPromptTimeout: TimeInterval = 60
    static let maxLogLines = 500

    @Published private(set) var status: Status = .idle
    @Published private(set) var log: [String] = []
    @Published var isConfirmingReset = false

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private let runScript: ScriptRunner
    private let verifyZoom: ZoomVerifier
    private let checkMediaAccess: MediaAccessChecker?
    private let homeDirectoryProvider: () -> String
    private let appPathProvider: () -> String
    private var task: Task<Void, Never>?

    init(
        runScript: ScriptRunner? = nil,
        verifyZoom: ZoomVerifier? = nil,
        checkMediaAccess: MediaAccessChecker? = nil,
        homeDirectoryProvider: @escaping () -> String = { NSHomeDirectory() },
        appPathProvider: @escaping () -> String = { ZoomLocation.appPath }
    ) {
        self.runScript = runScript ?? Self.runBash
        self.verifyZoom = verifyZoom ?? { try await ZoomBundleVerifier.verify(appPath: $0) }
        self.checkMediaAccess = checkMediaAccess
        self.homeDirectoryProvider = homeDirectoryProvider
        self.appPathProvider = appPathProvider
    }

    // MARK: - Actions

    func launchZoom() {
        start(reset: false)
    }

    func resetAndLaunchZoom() {
        isConfirmingReset = false
        start(reset: true)
    }

    func cancel() {
        task?.cancel()
    }

    /// Waits for the current action to finish. Used by tests.
    func waitUntilFinished() async {
        await task?.value
    }

    private func start(reset: Bool) {
        guard !isRunning else { return }
        log = []
        status = .running("Starting…")
        task = Task { [weak self] in
            await self?.perform(reset: reset)
        }
    }

    private func perform(reset: Bool) async {
        do {
            let home = try safeHomeDirectory()

            // Verify everything before anything is closed or deleted, so a bad Zoom
            // bundle or a rejected sandbox profile never leaves Zoom wiped and unlaunchable.
            step("Checking Zoom's signature")
            let appPath = appPathProvider()
            _ = try await verifyZoom(appPath)
            step("Checking the sandbox profile")
            _ = try await run(ShellCommands.makeSandboxProfileValidationCommand(homeDirectory: home), timeout: 15)

            if reset {
                step("Closing Zoom")
                _ = try await run(ShellCommands.stopZoom, timeout: 60)
                step("Wiping Zoom's local data")
                do {
                    _ = try await run(ShellCommands.makeResetZoomDataCommand(homeDirectory: home), timeout: 120)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw AppError.general("Wiping Zoom's data failed, so Zoom was not launched. \(error.localizedDescription)")
                }
            }

            step("Checking camera and microphone access")
            do {
                appendLog(try await ensureMediaAccess())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Zoom still launches; it can ask for access itself.
                appendLog("Warning: \(error.localizedDescription)")
            }

            step("Launching Zoom in the sandbox")
            // Re-verify right before launch; the launch script checks the signature again too.
            let bundle = try await verifyZoom(appPath)
            _ = try await run(
                ShellCommands.makeLaunchZoomCommand(
                    zoomBinaryPath: bundle.binaryPath,
                    homeDirectory: home,
                    verifiedAppPath: bundle.appPath
                ),
                timeout: 120
            )

            status = .succeeded(reset
                ? "Zoom's data was wiped and Zoom is running in the sandbox."
                : "Zoom is running in the sandbox.")
        } catch is CancellationError {
            status = .failed("Stopped.")
        } catch {
            if Task.isCancelled {
                status = .failed("Stopped.")
            } else {
                appendLog("Error: \(error.localizedDescription)")
                status = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func step(_ name: String) {
        status = .running(name + "…")
        appendLog("— " + name)
    }

    private func appendLog(_ text: String) {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        log.append(contentsOf: lines)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
    }

    private func run(_ script: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let output = try await runScript(script, timeout)
        appendLog(output)
        try Task.checkCancellation()
        return output
    }

    /// The physical home directory, refused when it is relative, the filesystem root, or missing.
    private func safeHomeDirectory() throws -> String {
        guard let normalized = ShellCommands.normalizedSafeHomeDirectory(homeDirectoryProvider()) else {
            throw AppError.general("Refusing to continue: the home directory is not a safe absolute path.")
        }
        let home = URL(fileURLWithPath: normalized).resolvingSymlinksInPath().standardized.path
        var isDirectory: ObjCBool = false
        guard ShellCommands.isSafeHomeDirectory(home),
              FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AppError.general("Refusing to continue: the home directory '\(home)' does not exist.")
        }
        return home
    }

    nonisolated private static func runBash(_ script: String, timeout: TimeInterval) async throws -> String {
        let result = try await BoundedProcessExecutor().run(
            executable: ShellCommands.bashPath,
            arguments: ["-c", script],
            timeout: timeout,
            maxOutputBytes: BoundedProcessExecutor.defaultMaxOutputBytes
        )
        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            throw AppError.processFailed(
                exitCode: Int(result.exitCode),
                message: output.isEmpty ? "Command failed with exit code \(result.exitCode)." : output
            )
        }
        return output
    }

    // MARK: - Camera and microphone

    /// macOS treats this app as the "responsible" process for the sandboxed Zoom, so
    /// camera and microphone access has to be granted to 1132 Fixer itself.
    private func ensureMediaAccess() async throws -> String {
        if let checkMediaAccess {
            return try await checkMediaAccess()
        }
        // macOS only shows the privacy prompt while the requesting app is frontmost.
        await bringAppToFront()
        let camera = await mediaAccess(for: .video, name: "Camera", usageKey: "NSCameraUsageDescription")
        let microphone = await mediaAccess(for: .audio, name: "Microphone", usageKey: "NSMicrophoneUsageDescription")
        let summary = [camera.message, microphone.message].joined(separator: "; ")
        guard camera.granted && microphone.granted else {
            throw AppError.general(summary)
        }
        return summary
    }

    private func mediaAccess(for mediaType: AVMediaType, name: String, usageKey: String) async -> (granted: Bool, message: String) {
        let settingsHint = "Open System Settings > Privacy & Security > \(name), enable 1132 Fixer, then try again."
        guard Bundle.main.object(forInfoDictionaryKey: usageKey) != nil else {
            return (false, "\(name) access cannot be requested because \(usageKey) is missing from the app bundle.")
        }
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return (true, "\(name) access granted")
        case .notDetermined:
            appendLog("Waiting for the macOS \(name) prompt — click Allow.")
            switch await requestMediaAccess(for: mediaType) {
            case .answered(true):
                return (true, "\(name) access granted")
            case .answered(false):
                return (false, "\(name) access was denied. \(settingsHint)")
            case .unanswered:
                return (false, "\(name) prompt went unanswered. \(settingsHint)")
            }
        case .denied:
            return (false, "\(name) access is denied. \(settingsHint)")
        case .restricted:
            return (false, "\(name) access is restricted by macOS or device management.")
        @unknown default:
            return (false, "\(name) access is in an unknown state.")
        }
    }

    private func requestMediaAccess(for mediaType: AVMediaType) async -> MediaAccessOutcome {
        guard !Task.isCancelled else { return .unanswered }
        let waiter = MediaAccessWaiter()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.mediaAccessPromptTimeout)
        timer.setEventHandler { waiter.finish(.unanswered) }
        timer.resume()

        AVCaptureDevice.requestAccess(for: mediaType) { granted in
            timer.cancel()
            waiter.finish(.answered(granted))
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
                waiter.attach(continuation)
            }
        } onCancel: {
            timer.cancel()
            waiter.finish(.unanswered)
        }
    }

    private func bringAppToFront() async {
        let app = NSApplication.shared
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
        app.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}
