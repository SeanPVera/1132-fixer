import Foundation

/// Verifies that a `zoom.us.app` bundle really is Zoom before 1132 Fixer launches it.
///
/// The Zoom location can be a user-selected path stored in `UserDefaults`, which any
/// process running as the user can rewrite. The launched binary runs as a child of this
/// app and therefore inherits its camera and microphone grants, so the bundle is checked
/// right before launch: its name, its resolved location, and its code signature (Zoom
/// Video Communications' Developer ID Team ID).
///
/// Everything runs through `Process` with an argument array, never through a shell.
///
/// Limitation: verification and launch are separate steps, so a bundle swapped in
/// between the two is not detected. The check is intended to stop a stale or tampered
/// preference, not an attacker who can already write inside the Zoom bundle.
enum ZoomBundleVerifier {
    /// Team ID of Zoom Video Communications, Inc.
    static let expectedTeamID = "BJ4HAAB9B3"
    static let requiredBundleName = "zoom.us.app"
    static let codesignPath = "/usr/bin/codesign"

    struct CommandResult {
        let status: Int32
        let output: String
    }

    /// Runs an executable with an argument array and returns its exit status and combined output.
    typealias CommandRunner = (_ executable: String, _ arguments: [String]) -> CommandResult

    struct VerifiedBundle: Equatable {
        /// Symlink-resolved path of the `zoom.us.app` bundle.
        let appPath: String
        /// Symlink-resolved path of the executable inside that bundle.
        let binaryPath: String
    }

    static let errorDomain = "1132Fixer.ZoomBundleVerifier"

    // MARK: - Pure helpers

    /// The code-signing requirement a genuine Zoom bundle must satisfy.
    static func makeRequirement(teamID: String = expectedTeamID) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Whether the last path component is `zoom.us.app` (case-insensitive, as on default macOS volumes).
    static func hasZoomBundleName(_ path: String) -> Bool {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent.lowercased() == requiredBundleName
    }

    /// Arguments for `codesign` that verify the bundle against the Zoom requirement.
    /// The `=` prefix makes codesign read the requirement as literal text.
    static func verifyArguments(bundlePath: String, teamID: String = expectedTeamID) -> [String] {
        ["--verify", "--strict", "-R=\(makeRequirement(teamID: teamID))", bundlePath]
    }

    /// Arguments for `codesign` that print the signature details (including `TeamIdentifier`).
    static func displayArguments(bundlePath: String) -> [String] {
        ["-dv", "--verbose=2", bundlePath]
    }

    /// Extracts the `TeamIdentifier=` value from `codesign -dv` output.
    static func parseTeamIdentifier(from output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Verification

    /// Verifies the bundle at `appPath` and returns the resolved bundle and executable paths
    /// that must be used for launching. Throws a user-readable error otherwise.
    static func verify(appPath: String, runner: CommandRunner = ZoomBundleVerifier.runProcess) throws -> VerifiedBundle {
        let trimmed = appPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw failure("No Zoom location is set.")
        }

        let resolvedApp = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().standardized.path
        guard hasZoomBundleName(resolvedApp) else {
            throw failure("Refusing to launch '\(resolvedApp)': it is not a '\(requiredBundleName)' bundle.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedApp, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw failure("Zoom was not found at '\(resolvedApp)'.")
        }

        let binary = ShellCommands.zoomBinaryPath(forAppPath: resolvedApp)
        let resolvedBinary = URL(fileURLWithPath: binary).resolvingSymlinksInPath().standardized.path
        guard resolvedBinary.hasPrefix(resolvedApp + "/") else {
            throw failure("Refusing to launch: the Zoom executable resolves to '\(resolvedBinary)', outside the Zoom bundle.")
        }
        guard FileManager.default.isExecutableFile(atPath: resolvedBinary) else {
            throw failure("The Zoom executable was not found inside '\(resolvedApp)'.")
        }

        let verifyResult = runner(codesignPath, verifyArguments(bundlePath: resolvedApp))
        guard verifyResult.status == 0 else {
            let detail = verifyResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure("Refusing to launch '\(resolvedApp)': its code signature is not a valid Zoom Video Communications signature (Team ID \(expectedTeamID)).\(detail.isEmpty ? "" : " codesign: \(detail.prefix(300))")")
        }

        let displayResult = runner(codesignPath, displayArguments(bundlePath: resolvedApp))
        guard displayResult.status == 0,
              parseTeamIdentifier(from: displayResult.output) == expectedTeamID else {
            throw failure("Refusing to launch '\(resolvedApp)': the signing Team ID is not \(expectedTeamID) (Zoom Video Communications).")
        }

        return VerifiedBundle(appPath: resolvedApp, binaryPath: resolvedBinary)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Default runner: executes the tool directly (no shell) and reads its output to EOF
    /// before waiting, so a chatty tool cannot fill the pipe and deadlock.
    static func runProcess(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
