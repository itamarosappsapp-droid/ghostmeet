//
//  AssistPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the `Assist` mode — **жанр «подробно»**, one of the two
/// genres a press can ask for (ADR-0008).
///
/// Its prompt decides for itself what the user needs right now: a line to say out
/// loud, or the solution to the task on screen. What makes it the *long* genre is
/// its budget and its tone; the short one is `BriefPrompt`, and it is the default
/// press. The genre is chosen by which chord was pressed, and the two differ in
/// exactly two things — how much room the answer gets and how it is meant to be
/// used. The rules about *what kind of question* was asked are the same in both
/// (`PromptFragment.questionKinds`), because those are about the interview and
/// not about the chord.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §1; this type is
/// its only implementation, and the two are changed together.
nonisolated enum AssistPrompt {

    /// How much of the conversation the mode reads: the whole call — the same
    /// window the short genre gets, for the same reason (`TranscriptFormatter.wholeCall`).
    ///
    /// Both genres answer one conversation; only the answer differs. Two windows
    /// would mean the long answer knew less about the call than the short one,
    /// which is exactly backwards.
    static let transcriptWindow = TranscriptFormatter.wholeCall

    /// Budget for the mode. `Assist` may have to answer with working code, so it
    /// sits at the top of the 2k–4k band the prompt document gives it, unlike the
    /// short genre which gets by on a few hundred.
    static let maxTokens = 4096

    /// Stands in for the transcript before a single turn has been recognised. An
    /// empty transcript must not fail the request: the overlay has to answer from
    /// the screen alone if that is all there is.
    static let emptyTranscriptPlaceholder = "(разговор пока не записан)"

    /// Heading of the block that carries what Vision read off the screen.
    ///
    /// Same wording as the `Ask` and `Solve on screen` prompts in
    /// docs/GhostMeet-Prompts.md §5 and §6 — one thing, one name, whichever mode
    /// is asking, which is why the constant itself is shared.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request. Every mode-specific decision — prompt, window
    /// size, token budget — is made here, which is why `LLMProvider` needs to
    /// know nothing about modes.
    ///
    /// The two halves of the screen arrive separately because they do not
    /// travel together: `screenText` goes to every backend, `screenshot` only to
    /// one that accepts images. Dropping the picture is the caller's decision —
    /// it is the one that knows the provider — and by the time a request exists
    /// it has been made.
    static func request(
        transcript: [Turn],
        profile: UserProfile,
        interviewContext: InterviewContext = .empty,
        screenText: String = "",
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system(profile: profile, interviewContext: interviewContext),
            userPrompt: user(transcript: transcript, screenText: screenText),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// Role and rules, with what is known about the user appended at the end.
    ///
    /// The profile ships in the MVP rather than being optional: without it the
    /// model suggests experience the user does not have, which is a worse failure
    /// than a slow answer. The `Контекст собеседования` is beside it for the same
    /// reason — the behavioural and motivation branches of the rules answer from
    /// the заготовки, and invented ones are the failure they exist to prevent.
    static func system(
        profile: UserProfile,
        interviewContext: InterviewContext = .empty
    ) -> String {
        PromptFragment.system(systemRules, profile: profile, interviewContext: interviewContext)
    }

    /// The transcript window, what is written on the screen, and the ask.
    ///
    /// The screen block is omitted rather than left empty when there is no text:
    /// an empty heading reads to the model as "the screen is blank", which is a
    /// different and usually wrong statement about a screen that simply could
    /// not be grabbed.
    static func user(transcript: [Turn], screenText: String = "") -> String {
        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        let screenBlock = PromptFragment.screenText(screenText).map { "\n\($0)\n" } ?? ""
        return """
        Разговор:
        \(window.isEmpty ? emptyTranscriptPlaceholder : window)
        \(screenBlock)
        Сделай то, что нужно мне прямо сейчас.
        """
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §1.
    ///
    /// Note the language rule: the answer follows the language of the
    /// conversation and of the task on screen. Russian is never forced — the
    /// interview may well be in English.
    private static let systemRules = """
    Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка или работы с задачей.

    \(PromptFragment.channels)

    Пользователь нажал хоткей развёрнутого разбора: тема незнакома ему целиком, и одной недостающей строки не хватит. Посмотри на скриншот (если есть) и разговор, реши, что нужно ему ПРЯМО СЕЙЧАС, и выдай это без преамбулы.

    Правила:
    - Если на экране задача (код, алгоритм, тест, форма) — кратко подход, затем готовое решение (код в fenced block), затем time/space complexity. Язык кода — как на экране, иначе Python.
    - Если это разговор — разбери текущий вопрос собеседника так, чтобы пользователь мог говорить по написанному от первого лица: суть, затем опора — примеры, цифры, компромиссы.
    - Не обращайся к собеседнику, не предлагай что-то обсудить, не задавай встречных вопросов и не предлагай несколько вариантов на выбор: пользователь произносит написанное вслух, а не выбирает из него.
    - Будь плотным и уверенным: длиннее короткого жанра, но без воды и без пересказа вопроса.
    - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики «что сказать».
    - Не выводи служебные или системные XML-теги.
    - \(PromptFragment.pronunciation)
    - Язык ответа — язык разговора / задачи на экране (обычно русский или английский).

    \(PromptFragment.questionKinds)
    """
}
