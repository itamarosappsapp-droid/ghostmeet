//
//  ManualClock.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// Clock the test moves by hand, so a ten-second monologue costs no real time —
/// and so does a budget that runs out.
///
/// Sleeping is the half that matters for the budget of a press. Recognition
/// racing a deadline is the one genuinely concurrent thing in the app, and a test
/// for it built on `Task.sleep` would be a coin toss: pass on a quiet machine,
/// fail on a busy one. Here the deadline fires exactly when the test says so.
///
/// Two rules make it deterministic rather than merely fast:
///
/// - `advance(by:)` wakes everything whose deadline it passed, before it returns.
/// - `waitForSleeper()` lets the test wait for the budget to *start* before
///   moving the hands. Without it, advancing first would set the deadline from
///   the already-advanced now, and the budget would never fire at all.
final class ManualClock: SessionClock, @unchecked Sendable {

    private struct Sleeper {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var current: TimeInterval
    private var sleepers: [Int: Sleeper] = [:]
    /// Sleeps cancelled before they managed to register. The cancellation
    /// handler can run before the body does, and a sleeper that missed its own
    /// cancellation would never be resumed.
    private var cancelled: Set<Int> = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var lastID = 0

    init(now: TimeInterval = 0) {
        current = now
    }

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Moves time forward and wakes everything whose deadline has passed.
    func advance(by interval: TimeInterval) {
        lock.lock()
        current += interval
        let due = sleepers.filter { $0.value.deadline <= current }
        for key in due.keys { sleepers.removeValue(forKey: key) }
        lock.unlock()

        for sleeper in due.values { sleeper.continuation.resume() }
    }

    func sleep(for interval: TimeInterval) async {
        lock.lock()
        lastID += 1
        let id = lastID
        lock.unlock()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                let deadline = current + interval
                if cancelled.remove(id) != nil || deadline <= current {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                lock.unlock()
                announceArrival()
            }
        } onCancel: {
            wake(id)
        }
    }

    /// Waits until some task is asleep on this clock.
    ///
    /// The synchronisation the budget tests are built on: press, wait for the
    /// deadline to be armed, then move the hands past it.
    func waitForSleeper() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard sleepers.isEmpty else {
                lock.unlock()
                continuation.resume()
                return
            }
            arrivals.append(continuation)
            lock.unlock()
        }
    }

    /// Whether anything is waiting on the clock right now.
    var hasSleepers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sleepers.isEmpty
    }

    private func announceArrival() {
        lock.lock()
        let waiting = arrivals
        arrivals.removeAll()
        lock.unlock()

        for continuation in waiting { continuation.resume() }
    }

    private func wake(_ id: Int) {
        lock.lock()
        guard let sleeper = sleepers.removeValue(forKey: id) else {
            cancelled.insert(id)
            lock.unlock()
            return
        }
        lock.unlock()
        sleeper.continuation.resume()
    }
}
