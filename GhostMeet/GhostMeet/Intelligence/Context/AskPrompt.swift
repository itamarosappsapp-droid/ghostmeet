//
//  AskPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the `Ask` mode — the user's own question, typed into
/// the overlay instead of waited for.
///
/// The mode exists because the genres can only answer what the
/// interlocutor said (ADR-0008), and the user sometimes needs something the
/// interlocutor never asked: «что это за ошибка на экране», «как мне это
/// свернуть». It is the one mode whose input is neither the transcript nor the
/// screen but a sentence the user wrote.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §5; this type is
/// its only implementation, and the two are changed together.
nonisolated enum AskPrompt {

    /// How much of the conversation the mode reads: the whole call, the same as
    /// the two genres (`TranscriptFormatter.wholeCall`).
    ///
    /// The old twelve-turn window assumed a background Summarizer would carry
    /// everything older. There is none, and `Ask` is the mode most likely to be
    /// about something said a while ago — «что он спрашивал про репликацию?» is
    /// unanswerable from the last twelve turns and trivially answerable from the
    /// call.
    static let transcriptWindow = TranscriptFormatter.wholeCall

    /// Budget for the mode: the bottom of the 2k–4k band the prompt document
    /// gives the screen-and-code modes (note 4).
    ///
    /// Not the 256–512 of Say/Follow-up: those produce one spoken line, whereas
    /// a free question can perfectly well be «перепиши этот запрос» and needs
    /// room for code. Not the 4096 of `Solve` either — the mode is told to
    /// answer «прямо и кратко», and a budget is a ceiling the user waits under.
    static let maxTokens = 2048

    /// Heading of the block that carries what Vision read off the screen.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request.
    ///
    /// The two halves of the screen arrive separately because they do not travel
    /// together: `screenText` goes to every backend, `screenshot` only to one
    /// that accepts images. Dropping the picture is the caller's decision — it is
    /// the one that knows the provider — and by the time a request exists it has
    /// been made.
    static func request(
        question: String,
        transcript: [Turn] = [],
        profile: UserProfile = .empty,
        interviewContext: InterviewContext = .empty,
        screenText: String = "",
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system(profile: profile, interviewContext: interviewContext),
            userPrompt: user(question: question, transcript: transcript, screenText: screenText),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// Role and rules, with what is known about the user appended at the end.
    ///
    /// The profile is here and not only in the genres because the question is
    /// often about the user themselves — «что ответить про мой опыт с Kafka» —
    /// and an answer built on experience they do not have is worse than none. The
    /// `Контекст собеседования` follows for the same reason and answers the same
    /// class of question typed out by hand: «что сказать про зарплату» has a
    /// prepared answer, and the model must read it rather than invent a number.
    static func system(
        profile: UserProfile,
        interviewContext: InterviewContext = .empty
    ) -> String {
        PromptFragment.system(systemRules, profile: profile, interviewContext: interviewContext)
    }

    /// The transcript window, what is written on the screen, and the question.
    ///
    /// Every block but the question is optional, exactly as the `{{#if …}}`
    /// guards in the document say. A conversation that has not started yet gets
    /// no placeholder here — unlike `Assist`, which is *about* the conversation
    /// and has to say that there is none. `Ask` is about the question, and the
    /// question is always there.
    static func user(question: String, transcript: [Turn] = [], screenText: String = "") -> String {
        var blocks: [String] = []

        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        if !window.isEmpty { blocks.append("Разговор:\n\(window)") }

        // The words on screen reach every backend, including the ones that
        // cannot take an image: for a local server or a CLI this is all they will
        // ever know about what the user is looking at.
        if let screen = PromptFragment.screenText(screenText) { blocks.append(screen) }

        blocks.append("Вопрос: \(question.trimmingCharacters(in: .whitespacesAndNewlines))")
        return blocks.joined(separator: "\n\n")
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §5.
    ///
    /// Note the language rule: the answer follows the language of the *question*,
    /// not of the conversation and not of the interface. A user typing in English
    /// during a Russian call is asking in English on purpose.
    private static let systemRules = """
    Ты — GhostMeet, real-time copilot с доступом к экрану пользователя и живому разговору («Them» / «You»).

    Ответь на вопрос пользователя прямо и кратко, опираясь на экран и сказанное. Без преамбулы («На основе скриншота…»).
    Язык ответа — язык вопроса пользователя.
    """
}
