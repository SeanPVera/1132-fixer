import Foundation
import Testing
@testable import _132Fixer

@Suite("Remediation result contracts")
struct RemediationContractTests {
    @Test(arguments: ["", "__1132_RESET_STATUS__=", "__1132_RESET_STATUS__=oops", "__1132_RESET_STATUS__=0\n__1132_RESET_STATUS__=1", "__1132_RESET_STATUS__=0\n__1132_RESET_STATUS__=0", "__1132_RESET_STATUS__=0 trailing", "__1132_RESET_STATUS__=256", "__1132_RESET_STATUS__=-1"])
    func invalidStatusIsNeverSuccessful(output: String) {
        #expect(OperationStatus.value(in: output, marker: "__1132_RESET_STATUS__") == nil)
        #expect(throws: (any Error).self) { try OperationStatus.requireSuccess(in: output, marker: "__1132_RESET_STATUS__") }
    }

    @Test func nonzeroIsValidEvidenceOfFailure() throws {
        #expect(OperationStatus.value(in: "detail\n__1132_RESET_STATUS__=1", marker: "__1132_RESET_STATUS__") == 1)
        #expect(throws: (any Error).self) { try OperationStatus.requireSuccess(in: "__1132_RESET_STATUS__=1", marker: "__1132_RESET_STATUS__") }
        try OperationStatus.requireSuccess(in: "detail\n__1132_RESET_STATUS__=0\n", marker: "__1132_RESET_STATUS__")
    }

    @Test func timeoutPolicyIncludesAuthorizationAndSettlementForBothPaths() {
        #expect(PrivilegedTimeoutPolicy.network.processTimeout == 280)
        #expect(PrivilegedTimeoutPolicy.dns.processTimeout == 250)
        for policy in [PrivilegedTimeoutPolicy.network, .dns] {
            let command = ShellCommands.makePrivilegedCommand(ShellCommands.makeRefreshDNSCommand(), policy: policy)
            let encoded = command.components(separatedBy: "/bin/echo '")[1].components(separatedBy: "'")[0]
            let script = String(decoding: Data(base64Encoded: encoded)!, as: UTF8.self)
            #expect(script.contains("/bin/sleep \(policy.watchdogSeconds)"))
            #expect(script.contains("__1132_PRIVILEGED_COMPLETE__="))
        }
    }

    @Test @MainActor func settlementPersistsAcrossAppRelaunchAndClearsOnlyAfterKnownReboot() {
        let name = "1132-settlement-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "boot-a")
        first.begin()
        #expect(first.requiresSettlement)
        #expect(PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "boot-a").requiresSettlement)
        #expect(PrivilegedOperationGuard(defaults: defaults, bootIdentifier: nil).requiresSettlement)
        #expect(!PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "boot-b").requiresSettlement)
        let unknown = PrivilegedOperationGuard(defaults: defaults, bootIdentifier: nil)
        unknown.begin()
        #expect(PrivilegedOperationGuard(defaults: defaults, bootIdentifier: "boot-c").requiresSettlement)
        unknown.settle(.completed)
        #expect(!unknown.requiresSettlement)
    }

    @Test func capabilityMatrixSeparatesHardwareArchitectureOSAndInterface() {
        for os in [13, 14, 15, 26] {
            for hardware in [NetworkEnvironment.Hardware.intel, .appleSilicon, .unknown] {
                for architecture in ["x86_64", "arm64", "unknown"] {
                    for interface in [ShellCommands.InterfaceKind.wifi, .ethernet] {
                        let environment = NetworkEnvironment(osMajor: os, hardware: hardware, executionArchitecture: architecture)
                        let capability = NetworkCapability.resolve(environment: environment, interface: interface)
                        let known = hardware != .unknown && architecture != "unknown" && !(hardware == .intel && architecture == "arm64")
                        let expected: NetworkCapability.Mechanism = !known ? .unavailable :
                            (os == 13 ? .legacyAttempt : (os >= 15 && interface == .wifi ? .manualPrivateWiFiAddress : .unavailable))
                        #expect(capability.mechanism == expected)
                        #expect(environment.isTranslated == (hardware == .appleSilicon && architecture == "x86_64"))
                        if expected == .manualPrivateWiFiAddress { #expect(capability.availableModes == [.off, .fixed, .rotating]) }
                    }
                }
            }
        }
        #expect(NetworkCapability.resolve(environment: .init(osMajor: 15, hardware: .appleSilicon, executionArchitecture: "arm64"), interface: nil).mechanism == .unavailable)
    }

    @Test func reconnectionAddressChangeAndModeAreIndependentObservations() {
        let unchanged = NetworkIdentityObservation(reconnected: true, previousAddress: "02:11:22:33:44:55", currentAddress: "02:11:22:33:44:55", verifiedMode: nil)
        #expect(unchanged.addressChanged == false)
        #expect(unchanged.summary.contains("did not change"))
        let unreadable = NetworkIdentityObservation(reconnected: true, previousAddress: nil, currentAddress: "02:11:22:33:44:55", verifiedMode: nil)
        #expect(unreadable.addressChanged == nil)
        #expect(unreadable.summary.contains("could not be established"))
    }

    @Test func consentAndCommandsUseTheSameBackedUpScope() {
        let home = "/Users/fixture"
        let backup = ShellCommands.makeBackupZoomDataCommand(homeDirectory: home)
        let reset = ShellCommands.makeResetZoomDataCommand(homeDirectory: home)
        let plan = RepairPlan.build(readiness: .initial(selectedAppPath: "/Applications/zoom.us.app", isCustomLocation: false), selectedAppPath: "/Applications/zoom.us.app", isCustomLocation: false)
        for path in ZoomStateScope.backedUpPaths {
            #expect(backup.contains("$home_physical/" + path))
            #expect(reset.contains("$home_physical/" + path))
            #expect(plan.affectedLocations.contains { $0.path.contains("~/" + path) })
        }
        #expect(plan.affectedLocations.first { $0.id == "backup-dir" }?.path == "~/" + ZoomStateScope.backupRelativeRoot)
        #expect(plan.affectedLocations.first { $0.id == "user-zoom-logs" }?.action.contains("not included in backup") == true)
    }

    @Test func processSelectorsScopeUserNamesAndPreserveWatchdogChildren() {
        #expect(ShellCommands.currentUserProcessArguments(name: "zoom.us").contains("-u"))
        let pattern = "^" + ShellCommands.currentUserProcessArguments(name: "zoom.us").last! + "$"
        #expect("zoom.us".range(of: pattern, options: .regularExpression) != nil)
        #expect("zoomXus".range(of: pattern, options: .regularExpression) == nil)
        #expect(ShellCommands.stopZoom.contains("zoom[.]us"))
        #expect(ShellCommands.stopZoom.contains("pgrep -u \"$uid\" -x"))
        #expect(ShellCommands.stopZoomUpdaters.contains("pkill -u \"$uid\" -x"))
        #expect(ShellCommands.makeTimeBoundedCommand("true", seconds: 1).contains("pkill -P"))
        #expect(ShellCommands.makeRefreshDNSCommand().contains("killall -HUP mDNSResponder"))
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
}

@Suite("Diagnostic privacy and byte budget")
struct DiagnosticPrivacyTests {
    @Test func homeRedactionAndAddressSanitizationComposeIndependently() {
        let text = "/Users/fixture/log 02:11:22:33:44:55 repeats 02-11-22-33-44-55; target 0211.2233.4466"
        for home in ["", "/", "/Users/fixture/"] {
            let safe = DiagnosticsCollector.sanitizedForSharing(text, homeDirectory: home)
            #expect(!safe.contains("02:11:22:33:44:55"))
            #expect(!safe.contains("02-11-22-33-44-55"))
            #expect(!safe.contains("0211.2233.4466"))
            #expect(safe.components(separatedBy: "[MAC#1]").count == 3)
            #expect(safe.contains("[MAC#2]"))
            if home == "/Users/fixture/" { #expect(!safe.contains("/Users/fixture")) }
        }
        #expect(DiagnosticsCollector.sanitizingMACAddresses("ff:ee:dd:cc:bb:aa") == "[MAC#1]")
    }

    @Test(arguments: [0, 1, 9, 64, 301, 1_048_576])
    func completeBudgetPreservesUTF8AndTransportBytes(limit: Int) {
        let text = "App version: 1.8.5\nOS: macOS 15\n--- Activity Log ---\n" + String(repeating: "🔧 old activity\n", count: 90_000) + "NEWEST ACTIVITY\n"
        let draft = ReportDraft.truncateDiagnosticsUTF8(text, maxBytes: limit)
        #expect(draft.data.count <= limit)
        #expect(Data(draft.text.utf8) == draft.data)
        #expect(String(data: draft.data, encoding: .utf8) != nil)
        #expect(BugReportService.truncatedAttachment(draft.data, limit: limit) == draft.data)
        if limit >= 301 {
            #expect(draft.text.hasPrefix("App version: 1.8.5"))
            #expect(draft.text.hasSuffix("NEWEST ACTIVITY\n"))
        }
    }
}
