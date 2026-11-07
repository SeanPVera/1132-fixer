import Foundation
import Darwin

/// Unprivileged cross-instance ownership. Root scripts never read or write this file.
@MainActor
final class WorkflowOwnershipLock {
    private let directory: URL
    private var descriptor: Int32 = -1

    init(directory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .resolvingSymlinksInPath().appendingPathComponent("Library/Application Support/1132Fixer", isDirectory: true)) {
        self.directory = directory
    }

    func acquire() -> Bool {
        guard descriptor == -1 else { return false }
        var ancestor = directory
        while ancestor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { return false }
            ancestor.deleteLastPathComponent()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let path = directory.appendingPathComponent("workflow.lock").path
        let candidate = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard candidate >= 0 else { return false }
        var info = stat()
        guard fstat(candidate, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            close(candidate)
            return false
        }
        descriptor = candidate
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
