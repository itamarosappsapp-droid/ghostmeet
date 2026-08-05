//
//  SolvePrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the `Solve on screen` mode — the finished solution to
/// the task the user is looking at.
///
/// It overlaps with `Assist`, which will also solve a task when it decides that
/// is what the user needs. The difference is who decides: `Assist` weighs the
/// screen against the conversation and may well answer the interviewer instead,
/// whereas this mode is the user saying «решай задачу, не разговор». In an
/// interview that is the moment the shared editor fills up and the questions
/// stop — exactly when guessing wrong costs the most.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §6; this type is
/// its only implementation, and the two are changed together.
nonisolated enum SolvePrompt {

    /// The mode reads **no** transcript at all — the document's user message for
    /// §6 has no transcript block.
    ///
    /// Deliberate rather than forgotten: the task is on the screen, and the
    /// conversation around it is what turns a solution into a lecture. The whole
    /// point of the mode is that it answers with working code instead of the
    /// discussion of it.
    static let readsTranscript = false

    /// Budget for the mode: the top of the 2k–4k band the prompt document gives
    /// `Solve` and `Assist` (note 4).
    ///
    /// The answer is a whole working solution plus its complexity, and an answer
    /// cut off mid-function is worth nothing at all — unlike a spoken line, which
    /// is still usable a sentence short.
    static let maxTokens = 4096

    /// Heading of the block that carries what Vision read off the screen.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request.
    ///
    /// Both halves of the screen are wanted here, and the mode is the reason the
    /// OCR pass exists at all: a downscaled screenshot is legible to a human and
    /// ambiguous to a model, and an identifier read wrong is a wrong solution.
    /// Neither half is required, though — a screen that could not be grabbed
    /// still produces a request, and the model is told to say what it is missing
    /// rather than to invent it.
    ///
    /// The `Профиль` is deliberately **not** appended. It is what stops the model
    /// claiming experience the user does not have, and there is nobody here to
    /// claim it to: the answer goes into an editor, not into a sentence the user
    /// says out loud. In a mode whose whole budget is the solution, a résumé is
    /// noise.
    static func request(
        screenText: String = "",
        screenshot: Data? = nil
    ) -> SuggestionRequest {
        SuggestionRequest(
            systemPrompt: system,
            userPrompt: user(screenText: screenText),
            screenshot: screenshot,
            maxTokens: maxTokens
        )
    }

    /// What is written on the screen, and the ask.
    static func user(screenText: String = "") -> String {
        guard let screen = PromptFragment.screenText(screenText) else { return ask }
        return "\(screen)\n\n\(ask)"
    }

    private static let ask = "Реши задачу, показанную на скриншоте."

    /// Verbatim from docs/GhostMeet-Prompts.md §6.
    ///
    /// Note the language rule: the explanation follows the language of the task
    /// on screen. Russian is never forced — the task is as likely to be in
    /// English, and so is the interview.
    static let system = """
    Ты — эксперт по решению задач с экрана (алгоритмы, код, тесты, формы, расчёты).

    На скриншоте (и/или в OCR-тексте) — задача. Ответь строго структурой:

    1. Одна строка: что требуется
    2. Краткий подход (2–4 предложения)
    3. Готовое решение в fenced code block (язык как на экране, иначе Python) ИЛИ готовый итоговый ответ, если это не код
    4. Для кода: time и space complexity

    Правила:
    - Не лей воду и не учи теории сверх необходимого.
    - Решение должно быть рабочим.
    - Если условия нечитаемы — напиши, чего не хватает, одним абзацем.
    - Язык пояснений — как у задачи на экране (часто русский или английский).
    """
}
