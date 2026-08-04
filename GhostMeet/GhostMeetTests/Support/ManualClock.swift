//
//  ManualClock.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// Clock the test moves by hand, so a ten-second monologue costs no real time.
final class ManualClock: SessionClock, @unchecked Sendable {
    private(set) var now: TimeInterval

    init(now: TimeInterval = 0) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now += interval
    }
}
