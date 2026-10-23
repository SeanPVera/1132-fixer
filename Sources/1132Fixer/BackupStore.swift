import Foundation

/// Read-only helpers for backups created by `ShellCommands.makeBackupZoomDataCommand`.
/// Backup creation and pruning stay in the shell command so they are part of the same
/// fail-closed operation that gates deletion of Zoom state.
enum BackupStore {
    private static let completionMarkerName = ".1132fixer-backup"

    static var rootURL: URL {
        rootURL(forHomeDirectory: NSHomeDirectory())
    }

    static func rootURL(forHomeDirectory homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/1132Fixer/Backups", isDirectory: true)
    }

    static func latestBackupURL(
        fileManager: FileManager = .default,
        rootURL: URL = BackupStore.rootURL
    ) -> URL? {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return candidates
            .filter { isManagedBackupURL($0, fileManager: fileManager, rootURL: rootURL) }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]) else {
                    return nil
                }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    static func isManagedBackupURL(
        _ url: URL,
        fileManager: FileManager = .default,
        rootURL: URL = BackupStore.rootURL
    ) -> Bool {
        if let rawAttributes = try? fileManager.attributesOfItem(atPath: url.path),
           rawAttributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return false
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.deletingLastPathComponent() == resolvedRoot else { return false }

        let name = resolvedURL.lastPathComponent
        let isCurrentName = name.hasPrefix("snapshot-")
        let isLegacyName = name.range(of: #"^[0-9]{4}-"#, options: .regularExpression) != nil
        guard isCurrentName || isLegacyName else { return false }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        // Legacy timestamp-only backups predate completion markers. Current snapshots
        // are usable only after the backup command records that every copy succeeded.
        guard isCurrentName else { return true }
        let markerURL = resolvedURL.appendingPathComponent(completionMarkerName, isDirectory: false)
        guard let markerAttributes = try? fileManager.attributesOfItem(atPath: markerURL.path) else {
            return false
        }
        return markerAttributes[.type] as? FileAttributeType == .typeRegular
    }

    static func availableCapacityBytes(at url: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }
}
