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
    ///
    /// The upper bound of the pause threshold is load-bearing beyond the slider:
    /// `TranscriptFormatter.mergeGap` has to stay strictly above it, or a user
    /// who turns the threshold all the way up would silently lose the merge that
    /// puts a broken question back together. 2.0 < 3.0 holds, and
    /// `TranscriptWindowTests` says so out loud.
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

// MARK: - Migration

/// Moves a stored threshold set forward when a shipped default is retired.
///
/// It exists because "optional on the way in" is not migration. A missing key
/// takes the current default, but a key that is *present* keeps whatever was
/// written — and one nudge of any of the four sliders in the proactive build
/// wrote all four, the 0.8 s pause threshold included. That threshold was a
/// latency compromise which ADR-0008 cancelled; leaving it in place would hand
/// the upgrade to a value the user never chose, and Whisper is markedly worse on
/// 0.8 s fragments than on three-second ones.
///
/// **Two mechanisms, and both are needed.** The rewrite fires on a value equal to
/// the retired default, because that is the only evidence there is: a file
/// carrying 0.8 says nothing about whether the user typed it or inherited it, and
/// betting on "inherited" is right for everyone who never opened that screen and
/// costs one slider drag to whoever really wanted 0.8. The version says *when* —
/// it makes the rewrite happen exactly once, so a user who deliberately sets 0.8
/// afterwards keeps it, which a match-only rule could never promise.
nonisolated enum TurnSegmentationMigration {

    /// Raised whenever a retired default has to reach people who already have a
    /// value stored. `0` is every build before ADR-0008.
    static let currentVersion = 1

    /// The pause threshold of the proactive build (ADR-0003), where every extra
    /// 100 ms was 100 ms before the first token.
    static let proactivePauseThreshold: TimeInterval = 0.8

    /// The stored set as this version wants to read it.
    static func migrate(
        _ stored: TurnSegmentationConfig,
        storedVersion: Int
    ) -> TurnSegmentationConfig {
        var migrated = stored
        if storedVersion < 1, isProactivePauseThreshold(stored.pauseThreshold) {
            migrated.pauseThreshold = TurnSegmentationConfig.default.pauseThreshold
        }
        return migrated
    }

    /// Compared with a tolerance rather than by `==`: the value makes a round
    /// trip through JSON, and a threshold that missed the migration by a rounding
    /// bit would be the whole bug again, silently.
    private static func isProactivePauseThreshold(_ value: TimeInterval) -> Bool {
        abs(value - proactivePauseThreshold) < 0.001
    }
}
