//
//  StubSpeechRecognizer.swift
//  GhostMeet
//

import Foundation

/// Recognition switched off on purpose.
///
/// While the segmentation thresholds are being tuned, turns carry no text: the
/// transcript shows their length only, so the pause, silence and minimum-length
/// thresholds can be judged by eye without the quality of recognition mixed in.
/// A real engine takes this place behind the same protocol.
nonisolated struct StubSpeechRecognizer: SpeechRecognizer {
    init() {}

    func transcribe(_ audio: SpeechAudio) async throws -> String { "" }
}
