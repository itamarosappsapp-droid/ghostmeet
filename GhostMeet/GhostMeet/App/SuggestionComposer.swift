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
    /// a placeholder, and so is a screen that could not be grabbed, because a
    /// suggestion built from half the context is worth more than a window that
    /// stays silent (ADR-0003).
    ///
    /// The screen arrives already captured rather than being fetched here: the
    /// engine starts it beside speech recognition so its cost is hidden, and
    /// composing stays synchronous and pure.
    ///
    /// `capabilities` is what decides whether the picture may be attached at
    /// all. This is the layer that drops it — a screenshot handed to a text-only
    /// backend is a failed request, not a worse answer.
    func compose(
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest
}

/// The composer the proactive loop actually runs: mode `Assist`.
///
/// `Assist` needs no choosing — its prompt decides for itself whether the user
/// needs a line to say out loud or the solution to the task on screen, which is
/// why closing a `Them` turn can fire it blind. The wording, the window size and
/// the token budget all belong to `AssistPrompt`; this type adds the one thing
/// neither the engine nor the prompt owns — the user's `Профиль` — and decides
/// which half of the screen the chosen backend is allowed to see.
struct AssistSuggestionComposer: SuggestionComposer {

    /// Read anew on every request, so a profile edited mid-call reaches the next
    /// suggestion instead of the next launch. The profile belongs to the user,
    /// not to the call, and so survives clearing the context.
    private let profile: () -> UserProfile

    init(profile: @escaping () -> UserProfile = { .empty }) {
        self.profile = profile
    }

    func compose(
        transcript: [Turn],
        screen: ScreenContext,
        accepting capabilities: ProviderCapabilities
    ) -> SuggestionRequest {
        AssistPrompt.request(
            transcript: transcript,
            profile: profile(),
            // The words on screen reach every backend, including the ones that
            // cannot take an image: for a local server or a CLI this is all they
            // will ever know about what the user is looking at.
            screenText: screen.text,
            screenshot: capabilities.acceptsImages ? screen.image : nil
        )
    }
}
