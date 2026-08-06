//
//  Clock.swift
//  GhostMeet
//

import Foundation

/// Source of time for everything that cuts speech into turns — and for the one
/// place that waits with a deadline.
///
/// The pause threshold, the minimum turn length and the forced flush all read
/// time from here instead of from the system clock. Without this seam a test for
/// a ten-second monologue would have to wait ten real seconds.
nonisolated protocol SessionClock: AnyObject, Sendable {
    /// Seconds since a fixed, arbitrary origin. Monotonic: never goes backwards.
    var now: TimeInterval { get }

    /// Suspends the calling task for `interval` of *this clock's* time.
    ///
    /// Reading `now` is not enough for a budget: something has to wake up when
    /// the budget runs out, and a poll would make the test that checks it depend
    /// on real time. A clock that can be slept on is what lets the test move the
    /// hands and see the deadline fire, deterministically and instantly.
    ///
    /// Returns early when the calling task is cancelled — the caller that lost
    /// interest must not be kept waiting for the clock.
    func sleep(for interval: TimeInterval) async
}

/// Production clock, backed by the system's monotonic uptime.
///
/// Uptime rather than wall time on purpose: wall time can jump when the machine
/// syncs its date, and a jump backwards would reopen turns that were already closed.
nonisolated final class SystemClock: SessionClock {
    init() {}

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(for interval: TimeInterval) async {
        guard interval > 0 else { return }
        // A cancelled sleep is not a failure — it is the budget being called off
        // because whatever it guarded finished first.
        try? await Task.sleep(for: .seconds(interval))
    }
}

extension SessionClock {

    /// Runs `work` under a deadline: comes back the moment it finishes, or the
    /// moment `budget` of this clock's time has passed, whichever is first.
    ///
    /// The loser is **dropped, not awaited**. That is the whole point and it is
    /// easy to get wrong: a task group would still wait for its remaining child
    /// at the end of the scope, and `Task.value` of a non-throwing task cannot be
    /// cut short by cancelling whoever is awaiting it — so a "timeout" built that
    /// way would time out and then block anyway.
    ///
    /// Dropping is safe here because of what this guards: speech recognition,
    /// which is never cancelled. The pass keeps running, its words still reach
    /// the transcript, and all that expires is the request's right to wait for
    /// them.
    ///
    /// A cancelled caller is a third way out and returns immediately — see
    /// `FirstToFinish.wait()`.
    ///
    /// - Returns: whether `work` finished inside the budget.
    @discardableResult
    func wait(upTo budget: TimeInterval, for work: @escaping @Sendable () async -> Void) async -> Bool {
        let outcome = FirstToFinish()

        let working = Task {
            await work()
            outcome.settle(inTime: true)
        }
        let deadline = Task {
            await self.sleep(for: budget)
            outcome.settle(inTime: false)
        }

        let inTime = await outcome.wait()

        // Cancelling the winner is a no-op; cancelling the loser is what stops a
        // sleeper hanging around until a budget nobody is waiting for elapses.
        working.cancel()
        deadline.cancel()
        return inTime
    }
}

/// The first of two answers wins; the second one is ignored.
///
/// Written by hand rather than taken from a task group because the loser must
/// not be awaited — see `wait(upTo:for:)`.
private final class FirstToFinish: @unchecked Sendable {

    private let lock = NSLock()
    private var waiter: CheckedContinuation<Bool, Never>?
    private var settled: Bool?

    /// Waits for whichever side reports first — or for the caller to lose
    /// interest.
    ///
    /// Cancellation is the third way out and it has to be here rather than left
    /// to the two racers. Neither of them is a child task, so cancelling the
    /// waiter reaches neither, and without this handler a superseded press sat
    /// out the whole recognition budget before noticing it had been replaced:
    /// four seconds in which the answer the user is actually waiting for had not
    /// been asked for yet.
    ///
    /// Cancelled counts as "did not finish in time", which is the truth about the
    /// work and, more to the point, is what the caller already handles.
    func wait() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if let settled {
                    lock.unlock()
                    continuation.resume(returning: settled)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            // Safe before the body has run: `settle` records the outcome, and the
            // body then finds it already there and resumes at once.
            settle(inTime: false)
        }
    }

    /// Reports an outcome. Everything after the first report is dropped.
    func settle(inTime: Bool) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = inTime
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: inTime)
    }
}
