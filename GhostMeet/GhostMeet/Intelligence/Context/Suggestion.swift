//
//  Suggestion.swift
//  GhostMeet
//

import Foundation

/// What the model produced for the user: a line to say out loud, a solution to
/// the task on screen, or a recap.
///
/// A `Подсказка` is always addressed to the user and never leaves for the call.
/// It arrives in fragments while the model writes, so it exists on screen long
/// before it is finished — `text` grows and `state` settles.
nonisolated struct Suggestion: Identifiable, Equatable, Sendable {

    nonisolated enum State: Equatable, Sendable {
        /// The model is still writing. `text` keeps growing.
        case streaming
        /// The model finished on its own.
        case complete
        /// The user pressed again and this one stopped being the answer they are
        /// waiting for (ADR-0008). Whatever arrived stays on screen — the feed
        /// keeps history — but nothing more will be appended.
        case superseded
        /// The model stopped before finishing. **Not a failure:** the text that
        /// arrived is on screen and readable, and the reason stands under it.
        ///
        /// A separate state and not `.failed` because the user does different
        /// things with them. A failure means there is nothing to say and the
        /// press is to be repeated; a cut answer is half of a usable one, said
        /// out loud as far as it goes while the rest is asked for again.
        case cut(String)
        /// It could not be produced. Shown inside the overlay window only.
        case failed(String)
    }

    let id: UUID

    /// Grows fragment by fragment while `state` is `.streaming`.
    var text: String

    var state: State

    /// What the user has to know about this answer before reading it, or `nil`
    /// when there is nothing to say.
    ///
    /// Not an error and not part of the answer: the request went out, the model
    /// replied, and something about the circumstances makes the reply narrower
    /// than the user expects. So far there is one such circumstance — a press
    /// made while nothing is being captured — and it deserves a sentence rather
    /// than a refusal, because the answer is still useful and refusing mid-
    /// interview would be worse than a thin answer.
    let notice: String?

    /// When generation started, for ordering in the feed.
    let startedAt: Date

    init(
        id: UUID = UUID(),
        text: String = "",
        state: State = .streaming,
        notice: String? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.notice = notice
        self.startedAt = startedAt
    }

    /// Whether anything more may still be appended.
    var isSettled: Bool {
        state != .streaming
    }
}
