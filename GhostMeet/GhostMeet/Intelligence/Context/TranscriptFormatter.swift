//
//  TranscriptFormatter.swift
//  GhostMeet
//

import Foundation

/// Renders the transcript the way every prompt expects to see it — the shared
/// `formatTranscript(turns, limit)` of docs/GhostMeet-Prompts.md.
///
/// Each line is `Them: …` or `You: …`. The label comes from the turn's channel
/// and therefore from the source of its audio, never from what was said: this is
/// the only place where the two-channel guarantee becomes visible to the model.
nonisolated enum TranscriptFormatter {

    /// The window handed to the model: the last `limit` turns, oldest first.
    ///
    /// - Parameter limit: How many turns to keep. `0` means all of them.
    ///
    /// Turns with no recognised text are left out. They exist in the transcript
    /// on purpose — a turn is kept even when recognition fails, because losing it
    /// would be worse — but a bare `Them:` in the prompt is noise that costs a
    /// slot in the window.
    static func format(_ turns: [Turn], limit: Int) -> String {
        let spoken = turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(label(for: turn.channel)): \(text)"
        }
        let window = limit > 0 ? spoken.suffix(limit) : spoken[...]
        return window.joined(separator: "\n")
    }

    /// The channel's name as the prompts spell it.
    static func label(for channel: Channel) -> String {
        switch channel {
        case .you: "You"
        case .them: "Them"
        }
    }
}
