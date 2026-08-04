//
//  TurnSegmenter.swift
//  GhostMeet
//

import Foundation

/// Thresholds that decide where one turn ends and the next one begins.
///
/// Every value here is configuration with a working default, never a constant
/// buried in the segmenter: the pause threshold in particular is the knob that
/// trades suggestion latency against cutting the speaker off mid-sentence.
nonisolated struct TurnSegmentationConfig: Equatable, Sendable {
    /// How much silence closes the current turn.
    var pauseThreshold: TimeInterval
    /// Speech shorter than this never becomes a turn: a cough or a chair creak
    /// that slipped past the gate is dropped instead of reaching recognition.
    var minimumTurnDuration: TimeInterval
    /// Frames quieter than this count as silence. They never open a turn, so a
    /// quiet room produces neither turns nor recognition calls.
    var silenceGateRMS: Float
    /// A turn is closed after this long even without any pause, so that a
    /// monologue reaches the transcript in pieces instead of after two minutes.
    var safetyFlushInterval: TimeInterval
    /// How often the engine re-checks pauses while no audio arrives, so that a
    /// stalled source cannot keep a turn open forever.
    var pauseCheckInterval: TimeInterval

    init(
        pauseThreshold: TimeInterval = 0.8,
        minimumTurnDuration: TimeInterval = 0.6,
        silenceGateRMS: Float = 0.01,
        safetyFlushInterval: TimeInterval = 10,
        pauseCheckInterval: TimeInterval = 0.1
    ) {
        self.pauseThreshold = pauseThreshold
        self.minimumTurnDuration = minimumTurnDuration
        self.silenceGateRMS = silenceGateRMS
        self.safetyFlushInterval = safetyFlushInterval
        self.pauseCheckInterval = pauseCheckInterval
    }

    /// Defaults from the spec: ~800 ms pause, 0.5–0.8 s minimum length, ~10 s flush.
    static let `default` = TurnSegmentationConfig()
}

/// A closed turn as it leaves the segmenter: audio and timing, but no text yet.
///
/// Recognition happens afterwards and may fail without the turn being lost.
nonisolated struct CapturedTurn: Sendable {
    let channel: Channel
    let samples: [Float]
    let sampleRate: Double
    /// Session-clock time the speech started at.
    let startedAt: TimeInterval
    /// Length of the speech, pauses inside the turn included.
    let duration: TimeInterval
}

/// Cuts the frames of a single channel into turns.
///
/// Knows nothing about recognition, about the transcript or about the other
/// channel: channels are segmented independently all the way, so one channel
/// falling silent can never close a turn of the other one.
nonisolated final class TurnSegmenter {
    /// Channel this segmenter is responsible for.
    let channel: Channel
    var config: TurnSegmentationConfig

    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var startedAt: TimeInterval?
    private var lastVoiceEndedAt: TimeInterval = 0

    init(channel: Channel, config: TurnSegmentationConfig = .default) {
        self.channel = channel
        self.config = config
    }

    /// Whether speech is currently being collected.
    var hasOpenTurn: Bool { startedAt != nil }

    /// Takes one captured frame.
    ///
    /// The clock is read when the frame is handed over, so the frame covers
    /// `time - frame.duration ..< time`. Returns a turn if this frame closed one.
    func accept(_ frame: AudioFrame, at time: TimeInterval) -> CapturedTurn? {
        if frame.rms >= config.silenceGateRMS {
            if startedAt == nil {
                startedAt = time - frame.duration
                sampleRate = frame.sampleRate
                samples.removeAll(keepingCapacity: true)
            }
            samples.append(contentsOf: frame.samples)
            lastVoiceEndedAt = time
        } else if startedAt != nil {
            // Silence inside an open turn is kept: the pause may still turn out
            // to be short, and dropping it would clip the words around it.
            samples.append(contentsOf: frame.samples)
        }
        return evaluate(at: time)
    }

    /// Lets time pass without any audio and closes the turn if it is due.
    func evaluate(at time: TimeInterval) -> CapturedTurn? {
        guard let startedAt else { return nil }
        let silenceSoFar = time - lastVoiceEndedAt
        let lengthSoFar = time - startedAt
        let pauseIsLongEnough = silenceSoFar >= config.pauseThreshold
        let speechRanTooLong = lengthSoFar >= config.safetyFlushInterval
        guard pauseIsLongEnough || speechRanTooLong else { return nil }
        return close()
    }

    /// Closes whatever is open, e.g. when the user stops listening.
    func flush() -> CapturedTurn? { close() }

    private func close() -> CapturedTurn? {
        guard let startedAt else { return nil }
        let duration = lastVoiceEndedAt - startedAt
        let captured = CapturedTurn(
            channel: channel,
            samples: samples,
            sampleRate: sampleRate,
            startedAt: startedAt,
            duration: duration
        )
        self.startedAt = nil
        samples.removeAll(keepingCapacity: true)
        // Too short to be speech: dropped, and recognition is never called for it.
        return duration >= config.minimumTurnDuration ? captured : nil
    }
}
