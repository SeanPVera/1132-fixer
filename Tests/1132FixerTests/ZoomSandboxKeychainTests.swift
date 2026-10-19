import Foundation
import Testing
@testable import _132Fixer

@Suite("Zoom Sandbox Keychain")
struct ZoomSandboxKeychainTests {
    @Test func sandboxedClientCanReadAndUpdateItsKeychain() async throws {
        let fileManager = FileManager.default
        let fixtureURL = fileManager.temporaryDirectory
            .appendingPathComponent("1132fixer-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: fixtureURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let fixture = fixtureURL.resolvingSymlinksInPath()
        let keychainDirectory = fixture.appendingPathComponent("Library/Keychains", isDirectory: true)
        try fileManager.createDirectory(at: keychainDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: fixture) }

        // The sandboxed probe creates a private keychain through the API. Unlike
        // `security create-keychain`, this does not add the disposable keychain to
        // the user's search list or involve the real login keychain.
        let keychainURL = keychainDirectory.appendingPathComponent("sandbox-test.keychain")
        let password = UUID().uuidString
        let account = "sandbox-test"
        let service = "1132FixerSandboxTest"

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

        let exercise = try await runSandboxed(
            profileURL: keychainProfileURL,
            executable: keychainProbe.path,
            arguments: [
                keychainURL.path,
                password,
                account,
                service,
                "initial-value",
                "updated-value",
            ]
        )
        #expect(exercise.status == 0, "Sandbox blocked Keychain exercise: \(exercise.output)")
        #expect(exercise.output.trimmingCharacters(in: .whitespacesAndNewlines) == "initial-value\nupdated-value")

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
    guard arguments.count == 7 else {
        fail("usage: keychain-probe keychain password account service initial-value updated-value")
    }

    let phaseURL = URL(fileURLWithPath: arguments[1])
        .deletingLastPathComponent()
        .appendingPathComponent("probe-phase")
    func mark(_ phase: String) {
        try? phase.write(to: phaseURL, atomically: true, encoding: .utf8)
    }
    mark("started")

    var keychain: SecKeychain?
    let password = arguments[2]
    let createStatus = password.withCString {
        SecKeychainCreate(arguments[1], UInt32(password.utf8.count), $0, false, nil, &keychain)
    }
    guard createStatus == errSecSuccess, let keychain else {
        fail("could not create keychain", status: createStatus)
    }
    mark("created keychain")

    let unlockStatus = password.withCString {
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true)
    }
    guard unlockStatus == errSecSuccess else {
        fail("could not unlock keychain", status: unlockStatus)
    }
    mark("unlocked keychain")

    let account = arguments[3]
    let service = arguments[4]
    let initialValue = arguments[5]
    let updatedValue = arguments[6]
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecAttrService as String: service,
        kSecValueData as String: Data(initialValue.utf8),
        kSecUseKeychain as String: keychain,
    ]
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        fail("could not create item", status: addStatus)
    }
    mark("created item")

    let matchQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: account,
        kSecAttrService as String: service,
        kSecMatchSearchList as String: [keychain],
    ]

    func readValue() -> String {
        mark("reading item")
        var query = matchQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            fail("could not read item", status: status)
        }
        mark("read item")
        guard let value = String(data: data, encoding: .utf8) else {
            fail("item was not UTF-8")
        }
        return value
    }

    let firstRead = readValue()
    guard firstRead == initialValue else { fail("initial value did not round-trip") }

    mark("writing item")
    let attributes = [kSecValueData as String: Data(updatedValue.utf8)]
    let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
    guard updateStatus == errSecSuccess else {
        fail("could not update item", status: updateStatus)
    }
    mark("wrote item")

    let secondRead = readValue()
    guard secondRead == updatedValue else { fail("updated value did not round-trip") }
    print(firstRead)
    print(secondRead)
    """#
}
