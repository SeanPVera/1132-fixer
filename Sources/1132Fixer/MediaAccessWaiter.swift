import Foundation

/// The result of a single `AVCaptureDevice.requestAccess` call.
enum MediaAccessOutcome: Equatable {
    case answered(Bool)
    case unanswered
}

final class MediaAccessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaAccessOutcome, Never>?
    private var outcome: MediaAccessOutcome?

    func finish(_ outcome: MediaAccessOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()

        pending?.resume(returning: outcome)
    }

    func attach(_ continuation: CheckedContinuation<MediaAccessOutcome, Never>) {
        lock.lock()
        if let outcome = self.outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
}
