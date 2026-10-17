import Foundation
import Testing
@testable import _132Fixer

@Suite("BackupStore")
struct BackupStoreTests {
    @Test func latestBackupSelectsNewestManagedDirectory() throws {
        let fixture = try BackupFixture()
        defer { fixture.remove() }

        let older = try fixture.makeDirectory(named: "2026-01-01T00-00-00Z", modified: Date(timeIntervalSince1970: 10))
        let newer = try fixture.makeDirectory(named: "snapshot-2026-01-02T00-00-00Z.ABC123", modified: Date(timeIntervalSince1970: 20))
        _ = try fixture.makeDirectory(named: "unrelated", modified: Date(timeIntervalSince1970: 30))

        #expect(BackupStore.latestBackupURL(rootURL: fixture.root) == newer)
        #expect(BackupStore.isManagedBackupURL(older, rootURL: fixture.root))
    }

    @Test func managedBackupMustBeADirectChildWithAnAppOwnedName() throws {
        let fixture = try BackupFixture()
        defer { fixture.remove() }

        let valid = try fixture.makeDirectory(named: "snapshot-2026-01-02T00-00-00Z.ABC123")
        let unrelated = try fixture.makeDirectory(named: "photos")
        let nested = valid.appendingPathComponent("snapshot-nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let file = fixture.root.appendingPathComponent("snapshot-not-a-directory")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))

        #expect(BackupStore.isManagedBackupURL(valid, rootURL: fixture.root))
        #expect(!BackupStore.isManagedBackupURL(unrelated, rootURL: fixture.root))
        #expect(!BackupStore.isManagedBackupURL(nested, rootURL: fixture.root))
        #expect(!BackupStore.isManagedBackupURL(file, rootURL: fixture.root))
    }

    @Test func managedBackupRejectsSymlinkEscapes() throws {
        let fixture = try BackupFixture()
        defer { fixture.remove() }

        let outside = fixture.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = fixture.root.appendingPathComponent("snapshot-escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(!BackupStore.isManagedBackupURL(link, rootURL: fixture.root))
        #expect(BackupStore.latestBackupURL(rootURL: fixture.root) == nil)
    }
}

private struct BackupFixture {
    let container: URL
    let root: URL

    init() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("1132fixer-backup-tests-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDirectory(named name: String, modified: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
