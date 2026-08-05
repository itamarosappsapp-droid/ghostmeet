//
//  PromptFragments.swift
//  GhostMeet
//

import Foundation

/// The blocks more than one mode puts in its message, kept in one place.
///
/// Not a convenience: the heading of the screen block and the shape of the
/// `Профиль` block are wording, and wording is what
/// docs/GhostMeet-Prompts.md is authoritative about. Three modes spelling
/// «Текст с экрана (OCR):» separately is three chances to drift from the
/// document — and from each other, which is worse: the model would be shown two
/// different names for one thing depending on which button the user pressed.
nonisolated enum PromptFragment {

    /// Heading of the block that carries what Vision read off the screen.
    /// Verbatim from docs/GhostMeet-Prompts.md §1 and §6.
    static let screenTextHeading = "Текст с экрана (OCR):"

    /// The screen block, or nothing at all when the screen gave up no text.
    ///
    /// The block is omitted rather than left empty on purpose: a bare heading
    /// reads to the model as "the screen is blank", which is a different — and
    /// usually wrong — statement about a screen that simply could not be grabbed.
    static func screenText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(screenTextHeading)\n\(trimmed)"
    }

    /// The system prompt with the user's `Профиль` appended — the
    /// `{{resume_context}}` slot of docs/GhostMeet-Prompts.md, note 5.
    ///
    /// Optional in the document, not optional here: without it the model
    /// suggests experience the user does not have, which is a worse failure than
    /// a slow answer. An unfilled profile adds nothing at all rather than an
    /// empty heading.
    static func system(_ rules: String, profile: UserProfile) -> String {
        guard !profile.isEmpty else { return rules }
        return """
        \(rules)

        Контекст о пользователе (резюме / роль / стек):
        \(profile.promptFragment)
        """
    }
}
