//
//  SpeechRecognizer.swift
//  GhostMeet
//

import Foundation

/// Audio of one closed turn, handed to recognition.
nonisolated struct SpeechAudio: Sendable, Equatable {
    /// Mono samples of the turn, trailing silence included.
    let samples: [Float]
    let sampleRate: Double

    init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }
}

/// Turns the audio of one closed turn into text.
///
/// Implementations are swappable (ADR-0001): `SessionEngine` never learns which
/// engine is behind this, and each channel is recognised on its own, so a slow
/// or failing pass on one channel does not hold up the other.
nonisolated protocol SpeechRecognizer: Sendable {
    func transcribe(_ audio: SpeechAudio) async throws -> String
}
