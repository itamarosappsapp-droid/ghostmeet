//
//  TurnSegmenter.swift
//  GhostMeet
//

import Foundation

/// Thresholds that decide where one turn ends and the next one begins.
///
/// Every value here is configuration with a working default, never a constant
/// buried in the segmenter: the pause threshold in particular is the knob that
/// decides how the interlocutor's speech is laid out in the transcript.
///
/// **It is no longer part of any latency budget.** While a closed `Them` turn
/// fired a suggestion by itself, every extra 100 ms of threshold was 100 ms
/// before the first token, and 800 ms was the compromise that made. Since
/// ADR-0008 a suggestion starts on a press, and the press force-closes the open
/// turn regardless — so the threshold buys nothing back by being small and costs
/// a question chopped into fragments. Do not lower it back on latency grounds:
/// there is no latency here to trade.
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

    /// - Parameter pauseThreshold: 1.5 s, and the number is an argument rather
    ///   than a taste. Hesitation pauses inside a sentence run 0.2–1.0 s and
    ///   clause-boundary pauses 1.0–1.5 s, so this covers both bands whole and an
    ///   ordinary interview question stops arriving in three pieces. It is 6.7×
    ///   below `safetyFlushInterval`, so silence still does the cutting rather
    ///   than the timer. The rarer case — an interviewer holding a two-second
    ///   silence mid-question — is caught afterwards by
    ///   `TranscriptFormatter.mergeGap`, which is the division of labour: the
    ///   threshold handles the common pause at the source, the merge handles the
    ///   long one at prompt time without touching what was stored.
    init(
        pauseThreshold: TimeInterval = 1.5,
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

    /// Working defaults: 1.5 s pause, 0.6 s minimum length, 10 s flush. The spec's
    /// original ~800 ms pause was a latency compromise and expired with ADR-0008.
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
    private var lastVoiceEndedAt: TimeInterval?

    /// Session-clock time of the last frame that was loud enough to count as
    /// speech, or `nil` while this channel has never been loud.
    ///
    /// Deliberately survives the turn it belonged to: what reads it is strict
    /// mode, which has to keep the `You` channel shut for a moment *after* the
    /// `Them` turn has closed — the room is still ringing then. Optional rather
    /// than zero so that "nothing has been heard yet" cannot be mistaken for
    /// "was heard at the very start of the session".
    var lastVoiceAt: TimeInterval? { lastVoiceEndedAt }

    /// Whether a `Реплика` is open right now.
    var hasOpenTurn: Bool { startedAt != nil }

    init(channel: Channel, config: TurnSegmentationConfig = .default) {
        self.channel = channel
        self.config = config
    }

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
        guard let startedAt, let lastVoiceEndedAt else { return nil }
        let silenceSoFar = time - lastVoiceEndedAt
        let lengthSoFar = time - startedAt
        let pauseIsLongEnough = silenceSoFar >= config.pauseThreshold
        let speechRanTooLong = lengthSoFar >= config.safetyFlushInterval
        guard pauseIsLongEnough || speechRanTooLong else { return nil }
        return close(keepingShortSpeech: false)
    }

    /// Closes whatever is open, e.g. when the user stops listening.
    ///
    /// The minimum length still applies: nobody asked for this turn, so a cough
    /// caught at the moment capture stopped is still a cough.
    func flush() -> CapturedTurn? { close(keepingShortSpeech: false) }

    /// Closes whatever is open **whatever its length** — for the moment the user
    /// asks for a suggestion.
    ///
    /// The minimum is deliberately skipped, and this is the whole reason the
    /// method exists. The user presses the instant the interlocutor stops
    /// talking, so what is open is the tail of the question — «…с Postgres?»,
    /// about 0.4 s, comfortably under `minimumTurnDuration` — and, on the other
    /// channel, the first words of their own answer, which are shorter still.
    /// Through the ordinary path that tail is not merely delayed, it is
    /// destroyed: `close()` empties the buffer before it decides to return nil.
    ///
    /// The filter is bypassed, not removed. Everything that closes by itself — a
    /// pause, the safety flush, stopping capture — keeps it, or a cough would
    /// become a `Реплика` again.
    func closeIgnoringMinimum() -> CapturedTurn? { close(keepingShortSpeech: true) }

    private func close(keepingShortSpeech: Bool) -> CapturedTurn? {
        guard let startedAt, let lastVoiceEndedAt else { return nil }
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
        return keepingShortSpeech || duration >= config.minimumTurnDuration ? captured : nil
    }
}
