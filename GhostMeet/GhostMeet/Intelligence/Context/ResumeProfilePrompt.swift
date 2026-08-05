//
//  ResumeProfilePrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the one request that turns a resume into a `Профиль`.
///
/// Not a suggestion and not a mode: it runs once, from the settings screen,
/// never reaches the suggestion feed, and is not cancelled by a `Them` turn —
/// the rules of ADR-0003 are about answers to the conversation, and this is a
/// piece of setup that happens before the call.
///
/// Two things make it unlike every other prompt here. It carries **no**
/// `{{resume_context}}` block, because it is what produces one. And its answer
/// is parsed rather than shown: the model is asked to reply in exactly the shape
/// `UserProfile.promptFragment` writes, so that `UserProfile.parsed(from:)` is
/// its inverse and the profile has one representation rather than two.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §8; this type is
/// its only implementation, and the two are changed together.
nonisolated enum ResumeProfilePrompt {

    /// Budget for the mode: four short lines, and nothing else is wanted.
    ///
    /// Far below the 2k–4k of the screen-and-code modes on purpose — a bigger
    /// ceiling here does not buy a better profile, it buys a model that starts
    /// retelling the resume.
    static let maxTokens = 512

    /// One assembled request. No screenshot and no transcript: the resume is
    /// the entire input, and a picture of the settings window would be noise.
    static func request(resumeText: String, isTruncated: Bool = false) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system,
            userPrompt: user(resumeText: resumeText, isTruncated: isTruncated),
            screenshot: nil,
            maxTokens: maxTokens
        )
    }

    /// The resume, and the note that it was cut short.
    ///
    /// The note is part of the prompt and not only of the UI: a model that knows
    /// it is holding the first pages writes a summary of them instead of
    /// wondering why the career ends mid-sentence.
    static func user(resumeText: String, isTruncated: Bool = false) -> String {
        var blocks: [String] = []
        if isTruncated {
            blocks.append("(резюме длинное — ниже только его первые \(ResumeDocument.maxCharacters) символов)")
        }
        blocks.append("Текст резюме:\n\(resumeText.trimmingCharacters(in: .whitespacesAndNewlines))")
        blocks.append("Собери профиль.")
        return blocks.joined(separator: "\n\n")
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §8.
    ///
    /// Note the rule about personal data. The profile is appended to the system
    /// prompt of every suggestion for the rest of the app's life, so a phone
    /// number copied into it would be sent again on every turn of every call —
    /// while being of no use whatsoever to a suggestion.
    static let system = """
    Ты — GhostMeet. Из текста резюме собери профиль пользователя: он будет дописан в system-промпт подсказок во время звонка.

    Ответь ровно четырьмя строками, с этими подписями и в этом порядке:
    Название: …
    Роль: …
    Опыт: …
    Стек: …

    Правила:
    - Название — как назвать этот профиль в списке, 1–3 слова: «Тимлид», «Синьор фулстек», «Data engineer».
    - Роль — одна строка: должность, на которой человек работает или на которую претендует.
    - Опыт — 1–3 предложения: годы, домены, заметные проекты. Не перечисляй места работы списком.
    - Стек — технологии через запятую, только те, с которыми человек действительно работал.
    - Ничего не додумывай: чего в резюме нет, того нет — оставь подпись с пустым значением.
    - Не переноси персональные данные: имя, телефон, почту, ссылки, названия работодателей. Подсказке они не нужны.
    - Никакого markdown, заголовков и пояснений — ни до четырёх строк, ни после.
    - Язык профиля — язык резюме.
    """
}
