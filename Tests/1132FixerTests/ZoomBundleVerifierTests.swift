import Foundation
import Testing
@testable import _132Fixer

@Suite("ZoomBundleVerifier")
struct ZoomBundleVerifierTests {

    @Test func requirementPinsZoomTeamID() {
        #expect(ZoomBundleVerifier.makeRequirement()
            == #"anchor apple generic and certificate leaf[subject.OU] = "BJ4HAAB9B3""#)
        #expect(ZoomBundleVerifier.expectedTeamID == "BJ4HAAB9B3")
    }

    @Test func bundleNameMustBeZoomUsApp() {
        #expect(ZoomBundleVerifier.hasZoomBundleName("/Applications/zoom.us.app"))
        #expect(ZoomBundleVerifier.hasZoomBundleName("/Users/me/Apps/zoom.us.app/"))
        #expect(!ZoomBundleVerifier.hasZoomBundleName("/Applications/Safari.app"))
        #expect(!ZoomBundleVerifier.hasZoomBundleName("/tmp/evil/zoom.us.app.evil"))
        #expect(!ZoomBundleVerifier.hasZoomBundleName("/tmp/notzoom.us.app"))
        #expect(!ZoomBundleVerifier.hasZoomBundleName(""))
    }

    @Test func verifyArgumentsUseStrictVerificationAgainstRequirement() {
        let args = ZoomBundleVerifier.verifyArguments(bundlePath: "/Applications/zoom.us.app")
        #expect(args.first == "--verify")
        #expect(args.contains("--strict"))
        #expect(args.contains("-R=" + ZoomBundleVerifier.makeRequirement()))
        #expect(args.last == "/Applications/zoom.us.app")
    }

    @Test func parsesTeamIdentifierFromCodesignOutput() {
        let output = """
        Executable=/Applications/zoom.us.app/Contents/MacOS/zoom.us
        Identifier=us.zoom.xos
        TeamIdentifier=BJ4HAAB9B3
        Sealed Resources version=2 rules=13 files=100
        """
        #expect(ZoomBundleVerifier.parseTeamIdentifier(from: output) == "BJ4HAAB9B3")
        #expect(ZoomBundleVerifier.parseTeamIdentifier(from: "TeamIdentifier=not set") == "not set")
        #expect(ZoomBundleVerifier.parseTeamIdentifier(from: "Identifier=x") == nil)
        #expect(ZoomBundleVerifier.parseTeamIdentifier(from: "TeamIdentifier=") == nil)
    }

    @Test func verifyRejectsNonZoomBundleName() {
        #expect(throws: (any Error).self) {
            try ZoomBundleVerifier.verify(appPath: "/Applications/Safari.app") { _, _ in
                Issue.record("codesign must not run for a wrongly named bundle")
                return .init(status: 0, output: "")
            }
        }
        #expect(throws: (any Error).self) {
            try ZoomBundleVerifier.verify(appPath: "  ") { _, _ in .init(status: 0, output: "") }
        }
    }

    /// Builds a throwaway `zoom.us.app` skeleton with an executable inside it.
    private func makeFakeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("1132fixer-tests-\(UUID().uuidString)")
        let macOS = root.appendingPathComponent("zoom.us.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("zoom.us")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return root
    }

    @Test func verifyAcceptsBundleWhenCodesignAndTeamIDMatch() throws {
        let root = try makeFakeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("zoom.us.app").path

        var calls: [[String]] = []
        let verified = try ZoomBundleVerifier.verify(appPath: app) { _, arguments in
            calls.append(arguments)
            return .init(status: 0, output: "TeamIdentifier=BJ4HAAB9B3\n")
        }
        #expect(calls.count == 2)
        #expect(verified.appPath.hasSuffix("/zoom.us.app"))
        #expect(verified.binaryPath == verified.appPath + "/Contents/MacOS/zoom.us")
    }

    @Test func verifyRejectsBadSignature() throws {
        let root = try makeFakeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("zoom.us.app").path

        #expect(throws: (any Error).self) {
            try ZoomBundleVerifier.verify(appPath: app) { _, _ in
                .init(status: 3, output: "code failed to satisfy specified code requirement(s)")
            }
        }
    }

    @Test func verifyRejectsWrongTeamID() throws {
        let root = try makeFakeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("zoom.us.app").path

        #expect(throws: (any Error).self) {
            try ZoomBundleVerifier.verify(appPath: app) { _, arguments in
                .init(status: 0, output: arguments.first == "--verify" ? "" : "TeamIdentifier=AAAAAAAAAA")
            }
        }
    }

    @Test func verifyResolvesSymlinksAndChecksResolvedName() throws {
        let root = try makeFakeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        // A symlink named zoom.us.app that points at a differently named bundle must be refused.
        let evil = root.appendingPathComponent("Evil.app")
        try FileManager.default.moveItem(at: root.appendingPathComponent("zoom.us.app"), to: evil)
        let link = root.appendingPathComponent("zoom.us.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: evil)

        #expect(throws: (any Error).self) {
            try ZoomBundleVerifier.verify(appPath: link.path) { _, _ in
                .init(status: 0, output: "TeamIdentifier=BJ4HAAB9B3")
            }
        }
    }

    @Test func validatedAppPathRequiresZoomBundleName() throws {
        let root = try makeFakeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("zoom.us.app").path
        #expect(ZoomLocation.validatedAppPath(app) == app)

        let renamed = root.appendingPathComponent("Other.app")
        try FileManager.default.moveItem(at: root.appendingPathComponent("zoom.us.app"), to: renamed)
        #expect(ZoomLocation.validatedAppPath(renamed.path) == nil)
    }
}
