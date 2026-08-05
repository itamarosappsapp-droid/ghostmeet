//
//  LLMProvider.swift
//  GhostMeet
//

import Foundation

/// One request to a model, already assembled: every mode-specific decision —
/// which prompt, how many turns of transcript, how many tokens — has been made
/// by the time a request exists.
///
/// The provider therefore knows nothing about modes, channels or the profile.
/// That is what lets a cloud provider, a local HTTP server and a CLI all sit
/// behind the same protocol (ADR-0001).
nonisolated struct SuggestionRequest: Equatable, Sendable {

    /// Role and rules. Carries the user's `Профиль` appended by the prompt
    /// builder, so the provider never assembles anything itself.
    var systemPrompt: String

    /// The assembled context: transcript window, question, OCR text.
    var userPrompt: String

    /// PNG bytes of the screen, attached to the *user* message. Nil until
    /// ticket 09 wires screen capture in.
    var screenshot: Data?

    /// Budget for this mode. Say/Follow-up are cheap, Solve/Assist are not.
    var maxTokens: Int
}

/// A single swappable model backend.
///
/// Streaming is the only shape offered on purpose: the whole product promise is
/// that a suggestion starts appearing while the model is still writing it. A
/// provider that can only answer in one piece yields one fragment.
nonisolated protocol LLMProvider: Sendable {

    /// Human-readable name for the settings screen and for error messages.
    var name: String { get }

    /// What this backend accepts. Read *before* a request is assembled: a
    /// screenshot handed to a text-only model is a failed request, not a worse
    /// answer, and the automatic loop attaches one every time (ADR-0003).
    var capabilities: ProviderCapabilities { get }

    /// Streams the answer in fragments, in order.
    ///
    /// **Cancellation is part of the contract, not a nicety.** A new `Them`
    /// turn cancels the in-flight suggestion (ADR-0003), so cancelling the
    /// consuming task must actually abandon the HTTP request rather than let it
    /// run to completion in the background.
    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error>
}

/// Why a suggestion could not be produced, in words meant for the user.
///
/// Never surfaced as a system notification: the banner would be drawn over
/// whatever the user is sharing and give the app away (ADR-0004).
nonisolated enum LLMFailure: Error, Equatable, Sendable {
    /// No API key in the Keychain yet.
    case missingKey
    /// The provider refused the key.
    case unauthorized
    /// Rate limit or quota.
    case throttled
    /// Anything else, with the provider's own wording.
    case provider(String)

    var message: String {
        switch self {
        case .missingKey: "Не задан ключ провайдера — откройте настройки."
        case .unauthorized: "Провайдер отклонил ключ."
        case .throttled: "Провайдер ограничил частоту запросов."
        case .provider(let text): text
        }
    }
}
