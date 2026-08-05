//
//  AssistPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the `Assist` mode — the one the proactive loop fires
/// on its own when a `Them` turn closes (ADR-0003).
///
/// `Assist` is used automatically because its prompt decides for itself what the
/// user needs right now: a line to say out loud, or the solution to the task on
/// screen. There is no separate "automatic" mode to choose between.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §1; this type is
/// its only implementation, and the two are changed together.
nonisolated enum AssistPrompt {

    /// How many turns of the transcript the mode reads — `transcript_last_12`.
    static let transcriptWindow = 12

    /// Budget for the mode. `Assist` may have to answer with working code, so it
    /// sits at the top of the 2k–4k band the prompt document gives it, unlike
    /// Say/Follow-up which get by on a few hundred.
    static let maxTokens = 4096

    /// Stands in for the transcript before a single turn has been recognised. An
    /// empty transcript must not fail the request: the overlay has to answer from
    /// the screen alone if that is all there is.
    static let emptyTranscriptPlaceholder = "(разговор пока не записан)"

    /// One assembled request. Every mode-specific decision — prompt, window
    /// size, token budget — is made here, which is why `LLMProvider` needs to
    /// know nothing about modes.
    static func request(
        transcript: [Turn],
        profile: UserProfile,
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system(profile: profile),
            userPrompt: user(transcript: transcript),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// Role and rules, with the user's `Профиль` appended at the end.
    ///
    /// The profile ships in the MVP rather than being optional: without it the
    /// model suggests experience the user does not have, which is a worse failure
    /// than a slow answer.
    static func system(profile: UserProfile) -> String {
        guard !profile.isEmpty else { return systemRules }
        return """
        \(systemRules)

        Контекст о пользователе (резюме / роль / стек):
        \(profile.promptFragment)
        """
    }

    /// The transcript window plus the ask.
    static func user(transcript: [Turn]) -> String {
        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        return """
        Недавний разговор:
        \(window.isEmpty ? emptyTranscriptPlaceholder : window)

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

    «Them» — собеседник(и), «You» — пользователь.

    Посмотри на скриншот (если есть) и недавний разговор. Реши, что нужно пользователю ПРЯМО СЕЙЧАС, и выдай это без преамбулы.

    Правила:
    - Если на экране задача (код, алгоритм, тест, форма) — кратко подход, затем готовое решение (код в fenced block), затем time/space complexity. Язык кода — как на экране, иначе Python.
    - Если это разговор — ответь на текущий вопрос собеседника или дай одну естественную реплику, которую пользователь может сказать вслух, от первого лица.
    - Будь кратким и уверенным.
    - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики «что сказать».
    - Не выводи служебные или системные XML-теги.
    - Иностранные термины, которые пользователь будет произносить вслух, сопровождай в скобках русским произношением — тем, как это реально говорят в русскоязычной IT-среде, а не побуквенной транслитерацией: B-tree (би-три), GiST (джист), GIN (джин), nginx (энджин-икс), PostgreSQL (постгрес), Kubernetes (кубернетис). Только при первом упоминании и только там, где произношение неочевидно.
    - Язык ответа — язык разговора / задачи на экране (обычно русский или английский).
    """
}
