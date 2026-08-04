//
//  CallFixture.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// A call the test can play out: someone speaks, someone stays quiet, time passes.
///
/// Audio arrives in short frames the way a capture backend delivers it, and the
/// clock moves along with it, so the scenarios read as a conversation and not as
/// a sequence of method calls.
@MainActor
struct CallFixture {
    let engine: SessionEngine
    let recognizer: RecognizerSpy

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(config: TurnSegmentationConfig = .default, recognisesAs text: String = "") {
        let clock = ManualClock()
        let recognizer = RecognizerSpy(reply: text)
        self.clock = clock
        self.recognizer = recognizer
        self.engine = SessionEngine(
            recognizer: recognizer,
            clock: clock,
            config: config
        )
    }

    /// Turns closed so far, in order.
    var transcript: [Turn] { engine.transcript }

    /// Someone speaks into `channel` for the given time.
    func someoneSpeaks(for seconds: TimeInterval, on channel: Channel = .you) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
    }

    /// Nobody speaks: the room is quiet, but the microphone keeps delivering audio.
    func silenceLasts(_ seconds: TimeInterval, on channel: Channel = .you) {
        feed(seconds: seconds) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    /// Time passes without a single frame — the capture backend went quiet.
    func timePassesWithoutAudio(_ seconds: TimeInterval) {
        clock.advance(by: seconds)
        engine.tick()
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}
