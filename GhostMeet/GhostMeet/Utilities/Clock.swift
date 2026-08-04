//
//  Clock.swift
//  GhostMeet
//

import Foundation

/// Source of time for everything that cuts speech into turns.
///
/// The pause threshold, the minimum turn length and the forced flush all read
/// time from here instead of from the system clock. Without this seam a test for
/// a ten-second monologue would have to wait ten real seconds.
nonisolated protocol SessionClock: AnyObject, Sendable {
    /// Seconds since a fixed, arbitrary origin. Monotonic: never goes backwards.
    var now: TimeInterval { get }
}

/// Production clock, backed by the system's monotonic uptime.
///
/// Uptime rather than wall time on purpose: wall time can jump when the machine
/// syncs its date, and a jump backwards would reopen turns that were already closed.
nonisolated final class SystemClock: SessionClock {
    init() {}

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
