//
//  AudioFrames.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// Audio a test can speak into the engine.
enum AudioFrames {
    static let sampleRate: Double = 16_000

    /// Someone talking: loud enough to pass the silence gate.
    static func speech(
        channel: Channel = .you,
        duration: TimeInterval = 0.1,
        loudness: Float = 0.3
    ) -> AudioFrame {
        frame(channel: channel, duration: duration, loudness: loudness)
    }

    /// A quiet room: audible only as noise, far below the gate.
    static func silence(
        channel: Channel = .you,
        duration: TimeInterval = 0.1,
        loudness: Float = 0.001
    ) -> AudioFrame {
        frame(channel: channel, duration: duration, loudness: loudness)
    }

    /// Square wave of the given amplitude, so that the RMS of the frame is
    /// exactly `loudness` and the silence gate can be aimed precisely.
    private static func frame(
        channel: Channel,
        duration: TimeInterval,
        loudness: Float
    ) -> AudioFrame {
        let count = Int((duration * sampleRate).rounded())
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? loudness : -loudness }
        return AudioFrame(channel: channel, samples: samples, sampleRate: sampleRate)
    }
}
