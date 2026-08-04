//
//  SuggestionComposer.swift
//  GhostMeet
//

import Foundation

/// Turns the transcript into a request a provider can take.
///
/// `SessionEngine` holds one of these instead of assembling prompts itself: how
/// many turns of transcript a mode reads, what it says to the model and how many
/// tokens it may spend are decisions of the prompt layer, and the engine must
/// stay unaware of them — the same way it stays unaware of which engine
/// recognised the speech (ADR-0001).
///
/// It also keeps the loop testable at the one seam: a test can watch what the
/// engine asked for without a prompt of its own.
@MainActor
protocol SuggestionComposer {

    /// Builds the request for one automatic suggestion.
    ///
    /// It cannot fail and it never refuses: an empty transcript is answered with
    /// a placeholder, because a suggestion before the first recognised phrase is
    /// worth more than a window that stays silent.
    func compose(transcript: [Turn]) -> SuggestionRequest
}

/// The composer the proactive loop actually runs: mode `Assist`.
///
/// `Assist` needs no choosing — its prompt decides for itself whether the user
/// needs a line to say out loud or the solution to the task on screen, which is
/// why closing a `Them` turn can fire it blind. The wording, the window size and
/// the token budget all belong to `AssistPrompt`; this type only supplies the
/// two things that are session state rather than prompt: the transcript and the
/// `Профиль`.
struct AssistSuggestionComposer: SuggestionComposer {

    /// Read anew on every request, so a profile edited mid-call reaches the next
    /// suggestion instead of the next launch. The profile belongs to the user,
    /// not to the call, and so survives clearing the context.
    private let profile: () -> UserProfile

    init(profile: @escaping () -> UserProfile = { .empty }) {
        self.profile = profile
    }

    func compose(transcript: [Turn]) -> SuggestionRequest {
        AssistPrompt.request(
            transcript: transcript,
            profile: profile(),
            // TODO(09 — Снимок экрана): every automatic request carries one.
            screenshot: nil
        )
    }
}
