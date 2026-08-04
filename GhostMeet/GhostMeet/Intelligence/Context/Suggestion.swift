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
        /// A newer `Them` turn arrived and this one stopped being the answer to
        /// the current question (ADR-0003). Whatever arrived stays on screen —
        /// the feed keeps history — but nothing more will be appended.
        case superseded
        /// It could not be produced. Shown inside the overlay window only.
        case failed(String)
    }

    let id: UUID

    /// The turn whose closing started this suggestion, so the feed can show
    /// what was being answered.
    let promptedBy: Turn.ID?

    /// Grows fragment by fragment while `state` is `.streaming`.
    var text: String

    var state: State

    /// When generation started, for ordering in the feed.
    let startedAt: Date

    init(
        id: UUID = UUID(),
        promptedBy: Turn.ID? = nil,
        text: String = "",
        state: State = .streaming,
        startedAt: Date
    ) {
        self.id = id
        self.promptedBy = promptedBy
        self.text = text
        self.state = state
        self.startedAt = startedAt
    }

    /// Whether anything more may still be appended.
    var isSettled: Bool {
        state != .streaming
    }
}
