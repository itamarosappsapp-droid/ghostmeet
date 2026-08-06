//
//  BriefPrompt.swift
//  GhostMeet
//

import Foundation

/// Builds the request for the **жанр «коротко»** — the default press (ADR-0008).
///
/// The genre exists because of what pressing means. The user does not press to
/// have the question answered for them: they know most of the answers. They press
/// when they do not know, do not remember or are unsure — and by then they are
/// already talking. What is missing is a term, a number, three bullets, a
/// distinction, and it is missing *now*, in the middle of a sentence that is
/// already under way. An essay from the start arrives too late to be said and too
/// long to be read while speaking.
///
/// That is also why the tone rules here are stricter than an assistant's. A
/// suggestion is spoken out loud whole, so anything addressed to the interlocutor
/// — «давай обсудим», a counter-question, a menu of options to choose from —
/// turns into the user saying it to their interviewer. The rules do not ask for
/// brevity and hope; they say what the text will be used for.
///
/// The authoritative wording lives in docs/GhostMeet-Prompts.md §9; this type is
/// its only implementation, and the two are changed together.
nonisolated enum BriefPrompt {

    /// How much of the conversation the genre reads: the whole call.
    ///
    /// A 45-minute interview is around 30 000 characters of transcript with both
    /// sides in it — one request, no compression (see
    /// `TranscriptFormatter.wholeCall`). The twelve-turn window this used to have
    /// was sized for a background Summarizer that does not exist, and it cost the
    /// model exactly the thing it needs to answer «а с чем сравнить?»: what was
    /// said before.
    static let transcriptWindow = TranscriptFormatter.wholeCall

    /// Budget for the genre — the 256–512 band the prompt document gives to the
    /// modes that produce something to be said aloud (note 4).
    ///
    /// A ceiling and a shape at once. Three or four lines of spoken Russian is
    /// 60–90 words, some 200–300 tokens; 512 leaves room for an identifier or a
    /// formula and no room for an essay. A budget that allowed one would get one.
    static let maxTokens = 512

    /// Stands in for the transcript before a single turn has been recognised.
    ///
    /// The block is never left empty and never sent as a bare heading: an empty
    /// heading reads to the model as "nothing was said", which is a different and
    /// usually wrong claim.
    static let emptyTranscriptPlaceholder = "(разговор пока не записан)"

    /// Heading of the block that carries what Vision read off the screen. Shared
    /// with every other mode — one thing, one name.
    static let screenTextHeading = PromptFragment.screenTextHeading

    /// One assembled request.
    ///
    /// The two halves of the screen arrive separately because they do not travel
    /// together: `screenText` goes to every backend, `screenshot` only to one
    /// that accepts images. Dropping the picture is the caller's decision — it is
    /// the one that knows the provider — and by the time a request exists it has
    /// been made.
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
    /// Both blocks ship in the MVP rather than being optional: the answer is said
    /// out loud in the first person, so experience the user does not have is worse
    /// than a slow answer — and the behavioural branch of the rules answers from
    /// the заготовки or from nothing.
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
        Я уже отвечаю. Дай то, чего мне не хватает.
        """
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §9.
    ///
    /// Note the language rule: the answer follows the language of the
    /// conversation. Russian is never forced — the interview may well be in
    /// English.
    private static let systemRules = """
    Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка.

    \(PromptFragment.channels)

    Пользователь нажал хоткей, потому что чего-то не знает, не помнит или сомневается. Он **уже начал отвечать вслух** и ждёт недостающего куска, а не ответа с начала.

    Твой текст он произнесёт целиком, как свою реплику. Поэтому:
    - Дай ровно то, чего не хватает: термин, цифру, различие, порядок из 2–4 пунктов. Не пересказывай вопрос и не начинай ответ заново.
    - Максимум 3–4 строки или 4 пункта. Без преамбулы, без вывода, без «итак» и «надеюсь, это поможет».
    - Пиши от первого лица, готовыми к произнесению фразами.
    - Не обращайся к собеседнику, не предлагай что-то обсудить, не задавай встречных вопросов и не предлагай несколько вариантов на выбор: выбрать по дороге пользователь не сможет — он читает вслух.
    - Не пиши, что чего-то не знаешь или что данных мало: скажи то, что можно сказать, короче.
    - Если на экране код или задача — дай недостающую строку, имя метода или оценку сложности, а не разбор целиком.
    - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики.
    - Не выводи служебные или системные XML-теги.
    - \(PromptFragment.pronunciation)
    - Язык ответа — язык разговора (обычно русский или английский).

    \(PromptFragment.questionKinds)
    """
}
