//
//  Turn.swift
//  GhostMeet
//

import Foundation

/// One of the two independent speech channels of a call.
///
/// A channel is decided by the source the audio came from and never by what was
/// said: everything the microphone picks up is `you`, even when the user reads
/// somebody else's question out loud; everything taken from the source app is `them`.
nonisolated enum Channel: String, Hashable, Sendable, CaseIterable {
    /// The user's own speech, captured from the microphone.
    case you
    /// Everyone else on the call, captured from the source app.
    case them
}

/// A turn: one continuous stretch of speech of a single channel, closed by a pause.
///
/// A turn always belongs to exactly one channel — there is no such thing as a
/// shared turn. The ordered sequence of turns is the transcript, the only
/// representation of the conversation the model ever sees.
nonisolated struct Turn: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Channel this turn belongs to, taken from the source of its audio.
    let channel: Channel
    /// Recognised text. Empty while recognition has not produced anything for
    /// this turn yet — and empty by design as long as recognition is stubbed.
    var text: String
    /// Session-clock time the speech started at.
    let timestamp: TimeInterval
    /// Length of the speech in seconds, pauses inside the turn included.
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        channel: Channel,
        text: String = "",
        timestamp: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.timestamp = timestamp
        self.duration = duration
    }
}
