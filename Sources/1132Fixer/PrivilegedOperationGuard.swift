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

    nonisolated static func currentBootIdentifier() -> String? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }
}
