import Foundation
import Darwin

/// An outer-process timeout cannot prove that a detached root shell has stopped.
/// Persist ownership before authorization; only terminal evidence or a new boot clears it.
@MainActor
final class PrivilegedOperationGuard {
    enum Outcome: String {
        case completed
        case cancelled
        case indeterminate
    }

    private let defaults: UserDefaults
    private let key = "privilegedOperationPendingBoot"
    private let bootIdentifier: String?
    private let ownershipLock: WorkflowOwnershipLock
    private(set) var lastOutcome: Outcome?

    init(defaults: UserDefaults = .standard, bootIdentifier: String? = PrivilegedOperationGuard.currentBootIdentifier(), ownershipLock: WorkflowOwnershipLock? = nil) {
        self.defaults = defaults
        self.bootIdentifier = bootIdentifier
        self.ownershipLock = ownershipLock ?? WorkflowOwnershipLock()
        defaults.synchronize()
        if let pending = defaults.string(forKey: key), pending != "unknown", let bootIdentifier, pending != bootIdentifier {
            defaults.removeObject(forKey: key)
        }
        if defaults.string(forKey: key) != nil { lastOutcome = .indeterminate }
    }

    var requiresSettlement: Bool {
        defaults.synchronize()
        return defaults.string(forKey: key) != nil
    }

    @discardableResult
    func begin() -> Bool {
        defaults.set(bootIdentifier ?? "unknown", forKey: key)
        lastOutcome = .indeterminate
        return defaults.synchronize()
    }

    func settle(_ outcome: Outcome) {
        lastOutcome = outcome
        if outcome != .indeterminate { defaults.removeObject(forKey: key) }
        defaults.synchronize()
    }

    func acquireWorkflowOwnership() -> Bool { ownershipLock.acquire() }
    func releaseWorkflowOwnership() { ownershipLock.release() }

    static let recoveryMessage = "Administrator operation completion is unknown. Further repair and launch actions are blocked. Earlier changes may remain; no rollback was performed. Restart your Mac before reopening 1132 Fixer to establish that the old privileged processes have ended. If it remains blocked, the saved boot identity could not be verified; export diagnostics for support."

    /// Prefer the per-boot session UUID: `kern.boottime` can be adjusted within one boot
    /// when the calendar clock is changed, which would look like a reboot and clear the
    /// pending marker too early. Boot time remains the fallback when the UUID is unreadable.
    nonisolated static func currentBootIdentifier() -> String? {
        var length = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1, length <= 256 {
            var buffer = [CChar](repeating: 0, count: length)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let uuid = String(decoding: bytes, as: UTF8.self)
                if UUID(uuidString: uuid) != nil { return "session:" + uuid }
            }
        }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }
}
