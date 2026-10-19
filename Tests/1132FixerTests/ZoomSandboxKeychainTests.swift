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

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "1132 Fixer sandbox fixture" as CFString,
            [] as CFArray,
            &access
        )
        try #require(accessStatus == errSecSuccess, "Could not create test item access: \(accessStatus)")
        let fixtureAccess = try #require(access)

        // This disposable fixture exercises sandbox access, not Keychain ACL prompts.
        // Mirror `security -A` so the headless runner never opens SecurityAgent.
        var aclList: CFArray?
        let aclListStatus = SecAccessCopyACLList(fixtureAccess, &aclList)
        try #require(aclListStatus == errSecSuccess, "Could not inspect test item access: \(aclListStatus)")
        let fixtureACLs = try #require(aclList as? [SecACL])
        for acl in fixtureACLs {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            let copyStatus = SecACLCopyContents(acl, &applications, &description, &prompt)
            try #require(copyStatus == errSecSuccess, "Could not inspect test item ACL: \(copyStatus)")

            let setStatus = SecACLSetContents(
                acl,
                nil,
                description ?? "1132 Fixer sandbox fixture" as CFString,
                prompt
            )
            try #require(setStatus == errSecSuccess, "Could not make test item noninteractive: \(setStatus)")
        }

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

        // Keychain Services consults per-user search-list metadata even when the
        // query names a private keychain explicitly. Use the real home here, just
        // as the production launch does; treating the temp fixture as $HOME would
        // deny the runner's real home and deadlock that lookup.
        let keychainProfileURL = fixture.appendingPathComponent("zoom-keychain.sb")
        try ShellCommands.makeZoomSandboxProfile(homeDirectory: NSHomeDirectory())
            .write(to: keychainProfileURL, atomically: true, encoding: .utf8)

        // Keep the destructive/private-data assertions isolated in a synthetic
        // home so the test never creates files in the developer's actual account.
        let restrictionProfileURL = fixture.appendingPathComponent("zoom-restrictions.sb")
        try ShellCommands.makeZoomSandboxProfile(homeDirectory: fixture.path)
            .write(to: restrictionProfileURL, atomically: true, encoding: .utf8)
        let keychainProbe = try await buildKeychainProbe(in: fixture)
        let probePhaseURL = keychainDirectory.appendingPathComponent("probe-phase")

        func runSandboxed(
            profileURL: URL,
            executable: String,
            arguments: [String]
        ) async throws -> CommandResult {
            do {
                return try await runCommand(
                    "/usr/bin/sandbox-exec",
                    arguments: ["-f", profileURL.path, executable] + arguments
                )
            } catch {
                let phase = (try? String(contentsOf: probePhaseURL, encoding: .utf8)) ?? "not started"
                throw CommandFailure(
                    message: "Sandboxed command failed during '\(phase)': \(error.localizedDescription)"
                )
            }
        }

        let readArguments = ["read", keychainURL.path, password, account, service]
        let read = try await runSandboxed(
            profileURL: keychainProfileURL,
            executable: keychainProbe.path,
            arguments: readArguments
        )
        #expect(read.status == 0, "Sandbox blocked Keychain read: \(read.output)")
        #expect(read.output.trimmingCharacters(in: .whitespacesAndNewlines) == "initial-value")

        // An update needs database writes plus sibling lock/temporary files. A
        // metadata-only or read-only exception would still fail this operation.
        let update = try await runSandboxed(
            profileURL: keychainProfileURL,
            executable: keychainProbe.path,
            arguments: ["write", keychainURL.path, password, account, service, "updated-value"]
        )
        #expect(update.status == 0, "Sandbox blocked Keychain update: \(update.output)")
        let updatedRead = try await runSandboxed(
            profileURL: keychainProfileURL,
            executable: keychainProbe.path,
            arguments: readArguments
        )
        #expect(updatedRead.status == 0, "Updated item could not be read: \(updatedRead.output)")
        #expect(updatedRead.output.trimmingCharacters(in: .whitespacesAndNewlines) == "updated-value")

        // The keychain compatibility fix must preserve the other private-data
        // and persistence restrictions in the same generated profile.
        let sshDirectory = fixture.appendingPathComponent(".ssh", isDirectory: true)
        try fileManager.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
        let sshKey = sshDirectory.appendingPathComponent("test-key")
        try Data("private-test-data".utf8).write(to: sshKey)
        let sshRead = try await runSandboxed(
            profileURL: restrictionProfileURL,
            executable: "/bin/cat",
            arguments: [sshKey.path]
        )
        #expect(sshRead.status != 0, "Sandbox allowed reading private SSH data")

        let agentsDirectory = fixture.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let agent = agentsDirectory.appendingPathComponent("test-agent.plist")
        let agentWrite = try await runSandboxed(
            profileURL: restrictionProfileURL,
            executable: "/usr/bin/touch",
            arguments: [agent.path]
        )
        #expect(agentWrite.status != 0, "Sandbox allowed writing a launch agent")
        #expect(!fileManager.fileExists(atPath: agent.path))
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private struct CommandFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func buildKeychainProbe(in fixture: URL) async throws -> URL {
        let sourceURL = fixture.appendingPathComponent("KeychainProbe.swift")
        let executableURL = fixture.appendingPathComponent("keychain-probe")
        try Self.keychainProbeSource.write(to: sourceURL, atomically: true, encoding: .utf8)

        let build = try await runCommand(
            "/usr/bin/xcrun",
            arguments: [
                "swiftc",
                sourceURL.path,
                "-framework", "Security",
                "-o", executableURL.path,
            ],
            timeout: 60
        )
        try #require(build.status == 0, "Could not compile Keychain probe: \(build.output)")
        return executableURL
    }

    private func runCommand(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 15
    ) async throws -> CommandResult {
        let result = try await BoundedProcessExecutor().run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maxOutputBytes: 64 * 1_024
        )
        return CommandResult(status: result.exitCode, output: result.combinedOutput)
    }

    private static let keychainProbeSource = #"""
    import Darwin
    import Foundation
    import Security

    func fail(_ message: String, status: OSStatus? = nil) -> Never {
        let suffix = status.map { ": \($0)" } ?? ""
        FileHandle.standardError.write(Data("\(message)\(suffix)\n".utf8))
        exit(1)
    }

    let arguments = CommandLine.arguments
    guard arguments.count >= 6 else {
        fail("usage: keychain-probe read|write keychain password account service [value]")
    }

    let phaseURL = URL(fileURLWithPath: arguments[2])
        .deletingLastPathComponent()
        .appendingPathComponent("probe-phase")
    func mark(_ phase: String) {
        try? phase.write(to: phaseURL, atomically: true, encoding: .utf8)
    }
    mark("started")

    var keychain: SecKeychain?
    let openStatus = SecKeychainOpen(arguments[2], &keychain)
    guard openStatus == errSecSuccess, let keychain else {
        fail("could not open keychain", status: openStatus)
    }
    mark("opened keychain")

    let password = arguments[3]
    let unlockStatus = password.withCString {
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true)
    }
    guard unlockStatus == errSecSuccess else {
        fail("could not unlock keychain", status: unlockStatus)
    }
    mark("unlocked keychain")

    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: arguments[4],
        kSecAttrService as String: arguments[5],
        kSecMatchSearchList as String: [keychain],
    ]

    switch arguments[1] {
    case "read":
        mark("reading item")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            fail("could not read item", status: status)
        }
        mark("read item")
        FileHandle.standardOutput.write(data)

    case "write":
        mark("writing item")
        guard arguments.count == 7 else { fail("write requires a value") }
        let attributes = [kSecValueData as String: Data(arguments[6].utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { fail("could not update item", status: status) }
        mark("wrote item")

    default:
        fail("unknown operation")
    }
    """#
}
