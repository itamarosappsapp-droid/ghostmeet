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
    ///
    /// The last line used to read «Дай то, чего мне не хватает» and worked
    /// against the whole system prompt: «дай мне» names the user as the
    /// addressee in the very last thing the model reads before generating, which
    /// is an invitation back into the «вот вам инструкция» register the rules
    /// above spend a paragraph forbidding. It now repeats the frame instead —
    /// last position, same contract.
    static func user(transcript: [Turn], screenText: String = "") -> String {
        let window = TranscriptFormatter.format(transcript, limit: transcriptWindow)
        let screenBlock = PromptFragment.screenText(screenText).map { "\n\($0)\n" } ?? ""
        return """
        Разговор:
        \(window.isEmpty ? emptyTranscriptPlaceholder : window)
        \(screenBlock)
        Я уже говорю вслух. Продолжи за меня: напиши мою следующую фразу — ровно то, чего мне не хватает.
        """
    }

    /// Verbatim from docs/GhostMeet-Prompts.md §9.
    ///
    /// **The shape of this prompt is as load-bearing as its words, and it is
    /// written for the model the user actually runs — gpt-4o through polza.ai,
    /// which follows instructions much more loosely than the tool these rules
    /// were trialled on.** Four properties are the fix for a live complaint and
    /// must not be "simplified":
    ///
    /// 1. **The contract stands at the top and is repeated in one line at the
    ///    bottom.** In a long system prompt both ends work and the middle is
    ///    background; the old prompt put the register rule third in a list of ten
    ///    and ended on reference data (the profile), so the strongest position
    ///    was spent on facts. The closing line is a repetition on purpose — it
    ///    costs a sentence and buys the rule that was ignored.
    /// 2. **`PromptFragment.voice` comes before the list, not inside it.** What
    ///    the text *is* has to be settled before any rule about how to write it.
    /// 3. **The list is short.** Fourteen bullets of equal weight were fog; eight
    ///    is what a weak follower still reads as rules.
    /// 4. **No bullet says «если это уместно».** Every reservation of that shape
    ///    was read as permission not to comply — that is precisely how the old
    ///    pronunciation rule died.
    ///
    /// The «ни одного факта о пользователе» bullet is not a style rule: with an
    /// empty `Контекст собеседования` every trialled variant invented a salary,
    /// a deadline or a shipped-without-incident outcome, and the user would have
    /// read it out loud as a fact about himself.
    ///
    /// Note the language rule: the answer follows the language of the
    /// conversation. Russian is never forced — the interview may well be in
    /// English.
    private static let systemRules = """
    Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка.

    \(PromptFragment.channels)

    Пользователь нажал хоткей, потому что чего-то не знает, не помнит или сомневается. Он **уже начал отвечать вслух** и ждёт недостающего куска, а не ответа с начала.

    \(PromptFragment.voice)

    \(PromptFragment.pronunciation)

    Говорит он коротко — он в середине собственной фразы:
    - Дай ровно то, чего не хватает: термин, цифру, различие, порядок из 2–4 шагов. Не пересказывай вопрос и не начинай ответ заново.
    - **Не больше 45 слов.** Каждую мысль — с новой строки, две-четыре строки, пустых строк между ними нет. Одним сплошным абзацем не пиши: его нельзя пробежать глазами, продолжая говорить. Без преамбулы, без вывода, без заголовков «Подход:», «Решение:», без «итак» и «надеюсь, это поможет».
    - Пункты — только там, где он и вслух перечислял бы по пальцам; каждый пункт тогда целая произносимая фраза, а не строка из справочника.
    - Ни одного слова в адрес собеседника: ни «используйте», «вы можете», «вам стоит», ни встречных вопросов, ни «давайте обсудим», ни нескольких вариантов на выбор — выбрать по дороге он не сможет, он читает подряд. Исключение одно: собеседник сам спросил, есть ли вопросы, — тогда вопрос и есть ответ, и берётся он из заготовок.
    - Ни одного факта о пользователе, которого нет в контексте: ни компании, ни проекта, ни срока, ни цифры о нём самом, ни суммы. Выдуманное он произнесёт вслух как своё и не переживёт уточняющий вопрос.
    - Чего-то не хватает — скажи короче то, что можно сказать. «Я не знаю», «данных мало», «сложно сказать» он вслух не произнесёт. Про заготовки и про то, чего нет в контексте, тоже молчи: это служебное, а не речь.
    - Если на экране код или задача — дай недостающую строку, имя метода или оценку сложности, а не разбор целиком. Не описывай скриншот («я вижу на экране…»), не бери реплику в кавычки, не выводи служебные или системные XML-теги.
    - Язык ответа — язык разговора. Разговор по-русски — скобки с произношением обязательны; разговор по-английски — термины идут как есть.

    \(PromptFragment.questionKinds)

    **Главное, ещё раз: ты пишешь фразу, которую пользователь через секунду скажет вслух своим голосом. Первое лицо, живые глаголы, не больше 45 слов и каждая мысль с новой строки, у каждого термина латиницей — скобка с произношением, и ни одного факта о нём, которого нет в контексте.**
    """
}
