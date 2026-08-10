import Testing
import Foundation
@testable import _132Fixer

@Suite("MediaAccessWaiter")
struct MediaAccessWaiterTests {

    @Test("Buffers an outcome that lands before the caller awaits")
    func bufferedOutcome() async {
        let waiter = MediaAccessWaiter()
        waiter.finish(.answered(true))

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
            waiter.attach(continuation)
        }

        #expect(outcome == .answered(true))
    }

    @Test("Resumes a waiting caller when the outcome arrives later")
    func lateOutcome() async {
        let waiter = MediaAccessWaiter()

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
            waiter.attach(continuation)
            DispatchQueue.global().async {
                waiter.finish(.unanswered)
            }
        }

        #expect(outcome == .unanswered)
    }

    @Test("Keeps the first outcome and ignores the ones that follow")
    func firstOutcomeWins() async {
        let waiter = MediaAccessWaiter()
        waiter.finish(.unanswered)
        waiter.finish(.answered(true))

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
            waiter.attach(continuation)
        }

        #expect(outcome == .unanswered)

        // A completion handler that fires after the timeout already resumed the
        // caller must not resume it a second time.
        waiter.finish(.answered(false))
    }

    @Test("A timeout racing the user's answer resumes the caller exactly once")
    func concurrentOutcomes() async {
        let waiter = MediaAccessWaiter()

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<MediaAccessOutcome, Never>) in
            waiter.attach(continuation)
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                waiter.finish(index.isMultiple(of: 2) ? .unanswered : .answered(true))
            }
        }

        #expect(outcome == .unanswered || outcome == .answered(true))
    }
}
