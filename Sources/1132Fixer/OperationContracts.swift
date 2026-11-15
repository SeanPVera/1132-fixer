import Foundation

/// A successful shell exit is not evidence that an operation completed.
enum OperationStatus {
    static func value(in output: String, marker: String) -> Int? {
        let lines = output.components(separatedBy: .newlines).filter { $0.hasPrefix(marker) }
        guard lines.count == 1, let line = lines.first, line.hasPrefix(marker + "=") else { return nil }
        let value = String(line.dropFirst(marker.count + 1))
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let status = Int(value), (0...255).contains(status) else { return nil }
        return status
    }

    static func requireSuccess(in output: String, marker: String) throws {
        guard value(in: output, marker: marker) == 0 else {
            throw AppError.general("Operation did not report one valid successful \(marker) result. Effects may be partial; no rollback was performed.")
        }
    }
}

struct PrivilegedTimeoutPolicy: Equatable {
    let authorizationAllowance: Int
    let watchdogSeconds: Int
    let settlementAllowance: Int

    var processTimeout: TimeInterval {
        TimeInterval(authorizationAllowance + watchdogSeconds + settlementAllowance)
    }

    /// Time the root shell gives its own restore traps after the watchdog fires, before it
    /// force-stops what is left. Kept inside `settlementAllowance` so the bounded cleanup
    /// finishes before the app-side timeout.
    var cleanupGraceSeconds: Int {
        max(1, min(10, settlementAllowance - 5))
    }

    static let network = Self(authorizationAllowance: 180, watchdogSeconds: 85, settlementAllowance: 15)
    static let dns = Self(authorizationAllowance: 180, watchdogSeconds: 55, settlementAllowance: 15)
}

enum ZoomStateScope {
    static let backupRelativeRoot = "Library/Application Support/1132Fixer/Backups"
    static let backedUpPaths = [
        "Library/Application Support/zoom.us",
        "Library/Caches/us.zoom.xos",
        "Library/Preferences/us.zoom.xos.plist",
        "Library/Saved Application State/us.zoom.xos.savedState",
    ]
    /// Exact log naming contract: `Library/Logs/zoom.us.log` and its numbered rotations
    /// (`zoom.us.log.1`, `zoom.us.log.2`, ...). Nothing else in `Library/Logs` is touched:
    /// near-miss names such as `zoom.us.logbook.txt` or `zoom.us.log.dir` are out of scope.
    /// Matching logs are copied into the backup (under `Logs/`) before they are removed.
    static let logsRelativeDirectory = "Library/Logs"
    static let logBaseName = "zoom.us.log"
    static let backupLogsSubdirectory = "Logs"
    static var removedLogsDescription: String {
        "~/\(logsRelativeDirectory)/\(logBaseName) and numbered rotations (\(logBaseName).1, \(logBaseName).2, …)"
    }
    static var consentPaths: String { backedUpPaths.map { "~/" + $0 }.joined(separator: ", ") }
}
