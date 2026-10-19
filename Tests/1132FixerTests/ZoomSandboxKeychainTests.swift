import Foundation
import Security
import Testing
@testable import _132Fixer

@Suite("Zoom Sandbox Keychain")
struct ZoomSandboxKeychainTests {
    @Test func sandboxedClientCanReadAndUpdateItsKeychain() async throws {
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
        let security = "/usr/bin/security"
        let account = "sandbox-test"
        let service = "1132FixerSandboxTest"
        var keychain: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(keychainURL.path, UInt32(password.utf8.count), $0, false, nil, &keychain)
        }
        try #require(status == errSecSuccess, "Could not create test keychain: \(status)")
        let createdKeychain = try #require(keychain)
        defer { #expect(SecKeychainDelete(createdKeychain) == errSecSuccess) }

        let unlockStatus = password.withCString {
            SecKeychainUnlock(createdKeychain, UInt32(password.utf8.count), $0, true)
        }
        try #require(unlockStatus == errSecSuccess, "Could not unlock test keychain: \(unlockStatus)")

        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(security, &trustedApplication)
        try #require(trustedStatus == errSecSuccess, "Could not trust security tool: \(trustedStatus)")
        let trustedSecurity = try #require(trustedApplication)

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "1132 Fixer sandbox fixture" as CFString,
            [trustedSecurity] as CFArray,
            &access
        )
        try #require(accessStatus == errSecSuccess, "Could not create test item access: \(accessStatus)")
        let fixtureAccess = try #require(access)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccess as String: fixtureAccess,
            kSecValueData as String: Data("initial-value".utf8),
            kSecUseKeychain as String: createdKeychain,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        try #require(addStatus == errSecSuccess, "Could not create test item: \(addStatus)")

        let profileURL = fixture.appendingPathComponent("zoom.sb")
        try ShellCommands.makeZoomSandboxProfile(homeDirectory: fixture.path)
            .write(to: profileURL, atomically: true, encoding: .utf8)

        func writeArguments(_ value: String) -> [String] {
            ["add-generic-password", "-U", "-a", account, "-s", service,
             "-w", value, keychainURL.path]
        }
        let readArguments = ["find-generic-password", "-a", account, "-s", service,
                             "-w", keychainURL.path]

        func runSandboxed(_ executable: String, arguments: [String]) async throws -> CommandResult {
            try await runCommand(
                "/usr/bin/sandbox-exec",
                arguments: ["-f", profileURL.path, executable] + arguments
            )
        }

        let read = try await runSandboxed(security, arguments: readArguments)
        #expect(read.status == 0, "Sandbox blocked Keychain read: \(read.output)")
        #expect(read.output.trimmingCharacters(in: .whitespacesAndNewlines) == "initial-value")

        // An update needs database writes plus sibling lock/temporary files. A
        // metadata-only or read-only exception would still fail this operation.
        let update = try await runSandboxed(security, arguments: writeArguments("updated-value"))
        #expect(update.status == 0, "Sandbox blocked Keychain update: \(update.output)")
        let updatedRead = try await runSandboxed(security, arguments: readArguments)
        #expect(updatedRead.status == 0, "Updated item could not be read: \(updatedRead.output)")
        #expect(updatedRead.output.trimmingCharacters(in: .whitespacesAndNewlines) == "updated-value")

        // The keychain compatibility fix must preserve the other private-data
        // and persistence restrictions in the same generated profile.
        let sshDirectory = fixture.appendingPathComponent(".ssh", isDirectory: true)
        try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        let sshKey = sshDirectory.appendingPathComponent("test-key")
        try Data("private-test-data".utf8).write(to: sshKey)
        let sshRead = try await runSandboxed("/bin/cat", arguments: [sshKey.path])
        #expect(sshRead.status != 0, "Sandbox allowed reading private SSH data")

        let agentsDirectory = fixture.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let agent = agentsDirectory.appendingPathComponent("test-agent.plist")
        let agentWrite = try await runSandboxed("/usr/bin/touch", arguments: [agent.path])
        #expect(agentWrite.status != 0, "Sandbox allowed writing a launch agent")
        #expect(!fileManager.fileExists(atPath: agent.path))
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private func runCommand(_ executable: String, arguments: [String]) async throws -> CommandResult {
        let result = try await BoundedProcessExecutor().run(
            executable: executable,
            arguments: arguments,
            timeout: 15,
            maxOutputBytes: 64 * 1_024
        )
        return CommandResult(status: result.exitCode, output: result.combinedOutput)
    }
}
