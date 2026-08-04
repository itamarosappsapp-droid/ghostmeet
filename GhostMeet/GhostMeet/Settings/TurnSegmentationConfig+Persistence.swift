//
//  TurnSegmentationConfig+Persistence.swift
//  GhostMeet
//

import Foundation

/// Persistence and admissible ranges for the turn-segmentation thresholds.
///
/// The thresholds themselves are declared once, in the audio layer next to the
/// segmenter that consumes them. What belongs to the settings layer lives here:
/// how they are stored, which values a user may choose, and what to do with a
/// preference that has been corrupted or hand-edited.
extension TurnSegmentationConfig: Codable {

    // MARK: - Persistence

    /// `pauseCheckInterval` is deliberately absent. It is an engine-internal
    /// tick rather than something the user tunes, so it has no business in the
    /// preferences file where a hand edit could stall the pipeline.
    private enum CodingKeys: String, CodingKey {
        case pauseThreshold
        case minimumTurnDuration
        case silenceGateRMS
        case safetyFlushInterval
    }

    /// Every key is optional on the way in: a preferences file written by an
    /// older build simply keeps the defaults for whatever it does not carry.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TurnSegmentationConfig.default
        self.init(
            pauseThreshold: try container.decodeIfPresent(TimeInterval.self, forKey: .pauseThreshold)
                ?? fallback.pauseThreshold,
            minimumTurnDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .minimumTurnDuration)
                ?? fallback.minimumTurnDuration,
            silenceGateRMS: try container.decodeIfPresent(Float.self, forKey: .silenceGateRMS)
                ?? fallback.silenceGateRMS,
            safetyFlushInterval: try container.decodeIfPresent(TimeInterval.self, forKey: .safetyFlushInterval)
                ?? fallback.safetyFlushInterval
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pauseThreshold, forKey: .pauseThreshold)
        try container.encode(minimumTurnDuration, forKey: .minimumTurnDuration)
        try container.encode(silenceGateRMS, forKey: .silenceGateRMS)
        try container.encode(safetyFlushInterval, forKey: .safetyFlushInterval)
    }

    // MARK: - Admissible ranges

    /// Bounds for the settings UI and for `clamped()`. Wide enough to be tuned
    /// per machine, narrow enough that no value can stall the pipeline — a zero
    /// pause threshold would close a turn on every frame.
    static let pauseThresholdRange: ClosedRange<TimeInterval> = 0.3...2.0
    static let minimumTurnDurationRange: ClosedRange<TimeInterval> = 0.3...1.5
    static let safetyFlushIntervalRange: ClosedRange<TimeInterval> = 3.0...30.0
    static let silenceGateRMSRange: ClosedRange<Float> = 0.001...0.2

    /// Pulls every threshold back into its admissible range. Applied to values
    /// arriving from outside the app, so a corrupted preference can never
    /// deafen the engine.
    func clamped() -> TurnSegmentationConfig {
        var clamped = self
        clamped.pauseThreshold = Self.pauseThresholdRange.clamping(pauseThreshold)
        clamped.minimumTurnDuration = Self.minimumTurnDurationRange.clamping(minimumTurnDuration)
        clamped.safetyFlushInterval = Self.safetyFlushIntervalRange.clamping(safetyFlushInterval)
        clamped.silenceGateRMS = Self.silenceGateRMSRange.clamping(silenceGateRMS)
        return clamped
    }
}

private extension ClosedRange {
    nonisolated func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
