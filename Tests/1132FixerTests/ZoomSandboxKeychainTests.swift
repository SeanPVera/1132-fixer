import Foundation
import Security
import Testing
@testable import _132Fixer

@Suite("Zoom Sandbox Keychain")
struct ZoomSandboxKeychainTests {
    @Test func sandboxedClientCanReadAndUpdateItsKeychain() throws {
        let fileManager = FileManager.default
        let fixture = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("1132fixer-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        let keychainDirectory = fixture.appendingPathComponent("Library/Keychains", isDirectory: true)
        try fileManager.createDirectory(at: keychainDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: fixture) }

        // Create a private keychain through the API: unlike `security create-keychain`,
        // this does not add a non-login keychain to the user's search list. All item
        // operations below name it explicitly, leaving the real login keychain alone.
        let keychainURL = keychainDirectory.appendingPathComponent("sandbox-test.keychain")
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(keychainURL.path, UInt32(password.utf8.count), $0, false, nil, &keychain)
        }
        try #require(status == errSecSuccess, "Could not create test keychain: \(status)")
        let createdKeychain = try #require(keychain)
        defer { #expect(SecKeychainDelete(createdKeychain) == errSecSuccess) }

        let profileURL = fixture.appendingPathComponent("zoom.sb")
        try ShellCommands.makeZoomSandboxProfile(homeDirectory: fixture.path)
            .write(to: profileURL, atomically: true, encoding: .utf8)

        let security = "/usr/bin/security"
        let account = "sandbox-test"
        let service = "1132FixerSandboxTest"
        func writeArguments(_ value: String) -> [String] {
            ["add-generic-password", "-a", account, "-s", service,
             "-w", value, "-T", security, keychainURL.path]
        }
        let deleteArguments = ["delete-generic-password", "-a", account, "-s", service,
                               keychainURL.path]
        let readArguments = ["find-generic-password", "-a", account, "-s", service,
                             "-w", keychainURL.path]

        // Trust only the system security tool for this test item so reads cannot
        // raise a Keychain approval dialog in the test runner.
        let setup = try runCommand(security, arguments: writeArguments("initial-value"))
        try #require(setup.status == 0, "Test item setup failed: \(setup.output)")

        func runSandboxed(_ executable: String, arguments: [String]) throws -> CommandResult {
            try runCommand("/usr/bin/sandbox-exec", arguments: ["-f", profileURL.path, executable] + arguments)
        }

        let read = try runSandboxed(security, arguments: readArguments)
        #expect(read.status == 0, "Sandbox blocked Keychain read: \(read.output)")
        #expect(read.output.trimmingCharacters(in: .whitespacesAndNewlines) == "initial-value")

        // Replacing an item (delete + add) inside the sandbox requires database writes
        // plus sibling lock/temporary files without triggering SecurityAgent's interactive
        // ACL-change prompt (which `add-generic-password -U ... -T` triggers on macOS).
        let deleteExisting = try runSandboxed(security, arguments: deleteArguments)
        #expect(deleteExisting.status == 0, "Sandbox blocked Keychain delete: \(deleteExisting.output)")
        let update = try runSandboxed(security, arguments: writeArguments("updated-value"))
        #expect(update.status == 0, "Sandbox blocked Keychain update: \(update.output)")
        let updatedRead = try runSandboxed(security, arguments: readArguments)
        #expect(updatedRead.status == 0, "Updated item could not be read: \(updatedRead.output)")
        #expect(updatedRead.output.trimmingCharacters(in: .whitespacesAndNewlines) == "updated-value")

        // The keychain compatibility fix must preserve the other private-data
        // and persistence restrictions in the same generated profile.
        let sshDirectory = fixture.appendingPathComponent(".ssh", isDirectory: true)
        try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        let sshKey = sshDirectory.appendingPathComponent("test-key")
        try Data("private-test-data".utf8).write(to: sshKey)
        let sshRead = try runSandboxed("/bin/cat", arguments: [sshKey.path])
        #expect(sshRead.status != 0, "Sandbox allowed reading private SSH data")

        let agentsDirectory = fixture.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let agent = agentsDirectory.appendingPathComponent("test-agent.plist")
        let agentWrite = try runSandboxed("/usr/bin/touch", arguments: [agent.path])
        #expect(agentWrite.status != 0, "Sandbox allowed writing a launch agent")
        #expect(!fileManager.fileExists(atPath: agent.path))
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private func runCommand(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
