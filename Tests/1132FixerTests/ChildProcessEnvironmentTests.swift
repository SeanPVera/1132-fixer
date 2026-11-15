import Foundation
import Testing
@testable import _132Fixer

/// F-001: every child process starts from a validated allowlist, never the app's
/// inherited environment (`BASH_ENV`, `ENV`, `BASH_FUNC_*`, `DYLD_*`, `PATH`, ...).
@Suite("Child process environment", .serialized)
struct ChildProcessEnvironmentTests {
    @Test func sanitizedKeepsOnlyValidatedAllowlistedValues() {
        let source = [
            "HOME": "/Users/fixture",
            "TMPDIR": "/var/folders/xy/T/",
            "USER": "fixture",
            "LANG": "en_US.UTF-8",
            "PATH": "/tmp/evil:/usr/bin",
            "BASH_ENV": "/tmp/evil.sh",
            "ENV": "/tmp/evil.sh",
            "SHELLOPTS": "xtrace",
            "BASH_FUNC_echo%%": "() { :; }",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "IFS": "/",
            "LC_ALL": "en_US.UTF-8\nBASH_ENV=/tmp/x",
            "LOGNAME": "bad name",
        ]
        let result = ChildProcessEnvironment.sanitized(source, homeFallback: nil, temporaryDirectoryFallback: nil)
        #expect(result == [
            "PATH": ChildProcessEnvironment.fixedPath,
            "HOME": "/Users/fixture",
            "TMPDIR": "/var/folders/xy/T/",
            "USER": "fixture",
            "LANG": "en_US.UTF-8",
        ])
    }

    @Test func invalidHomeAndTemporaryDirectoryFallBackToValidatedValues() {
        let result = ChildProcessEnvironment.sanitized(
            ["HOME": "relative", "TMPDIR": "/"],
            homeFallback: "/Users/fallback",
            temporaryDirectoryFallback: "/private/tmp/"
        )
        #expect(result["HOME"] == "/Users/fallback")
        #expect(result["TMPDIR"] == "/private/tmp/")
        let none = ChildProcessEnvironment.sanitized([:], homeFallback: "/", temporaryDirectoryFallback: "x")
        #expect(none == ["PATH": ChildProcessEnvironment.fixedPath])
    }

    @Test func executorChildrenSeeOnlyTheAllowlist() async throws {
        let result = try await BoundedProcessExecutor().run(
            executable: "/usr/bin/env", arguments: [], timeout: 10, maxOutputBytes: 64 * 1_024
        )
        #expect(result.exitCode == 0)
        var seen: [String: String] = [:]
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { seen[parts[0]] = parts[1] }
        }
        let allowed = Set(ChildProcessEnvironment.allowedKeys + ["PATH"])
        #expect(Set(seen.keys).isSubset(of: allowed), "unexpected keys: \(Set(seen.keys).subtracting(allowed))")
        #expect(seen["PATH"] == ChildProcessEnvironment.fixedPath)
    }

    /// Positive control plus the real check: with `BASH_ENV` set in this process, a plain
    /// inheriting child runs the probe file, while a child started by the executor does not.
    @Test func bashEnvInTheAppEnvironmentNeverRunsInExecutorChildren() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("1132-bash-env-" + UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let probeName = "probe-" + UUID().uuidString
        let marker = directory.appendingPathComponent("ran")
        let probe = directory.appendingPathComponent("probe.sh")
        // Only reacts to this test's own `$0`, so unrelated bash children are unaffected.
        try Data("case \"$0\" in \(probeName)) echo ran >> \(ShellCommands.shellSingleQuote(marker.path)) ;; esac\n".utf8).write(to: probe)

        let previous = getenv("BASH_ENV").map { String(cString: $0) }
        setenv("BASH_ENV", probe.path, 1)
        defer {
            if let previous { setenv("BASH_ENV", previous, 1) } else { unsetenv("BASH_ENV") }
        }

        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/bash")
        control.arguments = ["-c", ":", probeName]
        try control.run()
        control.waitUntilExit()
        #expect(fileManager.fileExists(atPath: marker.path), "positive control: inherited BASH_ENV should run")
        try? fileManager.removeItem(at: marker)

        let result = try await BoundedProcessExecutor().run(
            executable: "/bin/bash", arguments: ["-c", ":", probeName], timeout: 10, maxOutputBytes: 4_096
        )
        #expect(result.exitCode == 0)
        #expect(!fileManager.fileExists(atPath: marker.path), "BASH_ENV ran inside an executor child")
    }
}
