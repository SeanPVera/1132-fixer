import Foundation
import Testing
@testable import _132Fixer

@Suite("Packaged SwiftPM resource lookup")
struct PackagedResourcesTests {
    @Test(arguments: [false, true])
    func runtimeFindsBothValidBundleLayouts(structured: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("1132-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources")
        let bundle = resources.appendingPathComponent(PackagedResources.bundleName)
        let directory = structured ? bundle.appendingPathComponent("Contents/Resources") : bundle
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = directory.appendingPathComponent("FIXER_BUG_REPORT_TOKEN")
        try "fixture-token".write(to: token, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("Contents/MacOS/1132 Fixer")
        let found = PackagedResources.resourceURL(named: "FIXER_BUG_REPORT_TOKEN", executableURL: executable, mainResourceURL: resources)
        #expect(found == token)
        #expect(PackagedResources.resourceURL(named: "missing", executableURL: executable, mainResourceURL: resources) == nil)
        try FileManager.default.removeItem(at: token)
        try FileManager.default.createSymbolicLink(at: token, withDestinationURL: directory.appendingPathComponent("missing"))
        #expect(PackagedResources.resourceURL(named: "FIXER_BUG_REPORT_TOKEN", executableURL: executable, mainResourceURL: resources) == nil)
    }

    @Test func cliBuildFindsResourceBundleBesideExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("1132-cli-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent(PackagedResources.bundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let resource = bundle.appendingPathComponent("FIXER_BUG_REPORT_ENDPOINT")
        try "https://example.invalid/report".write(to: resource, atomically: true, encoding: .utf8)
        #expect(PackagedResources.resourceURL(named: "FIXER_BUG_REPORT_ENDPOINT", executableURL: root.appendingPathComponent("1132 Fixer"), mainResourceURL: nil) == resource)
    }
}
