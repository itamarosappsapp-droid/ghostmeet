//
//  TurnSegmentationSettings.swift
//  GhostMeet
//

import Foundation

/// Thresholds that decide when a stream of audio frames becomes a closed turn.
///
/// Deliberately a plain, isolation-free value type: `SessionEngine` receives it
/// as configuration and reads it from the audio path, so nothing here may be
/// bound to the main actor or to the UI layer. The spec is explicit that these
/// are settings with defaults, never constants baked into the engine.
nonisolated struct TurnSegmentationSettings: Codable, Equatable, Sendable {

    /// Silence, in seconds, that closes the current turn. Spec default: 800 ms.
    var pauseThreshold: TimeInterval

    /// Shortest speech span, in seconds, that may become a turn. Anything
    /// shorter is dropped instead of being handed to recognition.
    var minimumTurnDuration: TimeInterval

    /// Safety valve for monologues without pauses: the turn is flushed after
    /// this much continuous speech even when no pause was detected.
    var safetyFlushInterval: TimeInterval

    /// Linear RMS below which a frame counts as silence and never opens a turn.
    var rmsGateThreshold: Float

    // MARK: - Defaults

    /// The values the spec prescribes. A store with nothing persisted yet
    /// starts here.
    static let `default` = TurnSegmentationSettings()

    init(
        pauseThreshold: TimeInterval = 0.8,
        minimumTurnDuration: TimeInterval = 0.6,
        safetyFlushInterval: TimeInterval = 10,
        rmsGateThreshold: Float = 0.01
    ) {
        self.pauseThreshold = pauseThreshold
        self.minimumTurnDuration = minimumTurnDuration
        self.safetyFlushInterval = safetyFlushInterval
        self.rmsGateThreshold = rmsGateThreshold
    }

    // MARK: - Admissible ranges

    /// Bounds for the settings UI and for `clamped()`. They are wide enough to
    /// be tuned per machine and narrow enough that no value can stall the
    /// pipeline (a zero pause threshold would close a turn on every frame).
    static let pauseThresholdRange: ClosedRange<TimeInterval> = 0.3...2.0
    static let minimumTurnDurationRange: ClosedRange<TimeInterval> = 0.3...1.5
    static let safetyFlushIntervalRange: ClosedRange<TimeInterval> = 3.0...30.0
    static let rmsGateThresholdRange: ClosedRange<Float> = 0.001...0.2

    /// Pulls every threshold back into its admissible range. Applied when
    /// values come from outside the app (a decoded, possibly hand-edited
    /// defaults plist), so a corrupted preference can never deafen the engine.
    func clamped() -> TurnSegmentationSettings {
        TurnSegmentationSettings(
            pauseThreshold: Self.pauseThresholdRange.clamping(pauseThreshold),
            minimumTurnDuration: Self.minimumTurnDurationRange.clamping(minimumTurnDuration),
            safetyFlushInterval: Self.safetyFlushIntervalRange.clamping(safetyFlushInterval),
            rmsGateThreshold: Self.rmsGateThresholdRange.clamping(rmsGateThreshold)
        )
    }
}

extension TurnSegmentationSettings {
    /// The same thresholds in the shape `SessionEngine` consumes.
    ///
    /// The settings layer owns what the user edits and what is persisted;
    /// `TurnSegmentationConfig` is how it travels into the audio path. Values
    /// the user never sets — currently the engine's pause-check tick — keep
    /// their engine-side defaults.
    ///
    /// Two types describing one concept is one too many: when the audio layer
    /// settles, one of them should absorb the other and this adapter should go.
    nonisolated var engineConfig: TurnSegmentationConfig {
        var config = TurnSegmentationConfig.default
        config.pauseThreshold = pauseThreshold
        config.minimumTurnDuration = minimumTurnDuration
        config.silenceGateRMS = rmsGateThreshold
        config.forcedFlushInterval = safetyFlushInterval
        return config
    }
}

private extension ClosedRange {
    nonisolated func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
