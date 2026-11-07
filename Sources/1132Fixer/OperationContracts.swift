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
    static let removedLogPattern = "Library/Logs/zoom.us.log*"
    static var consentPaths: String { backedUpPaths.map { "~/" + $0 }.joined(separator: ", ") }
}
