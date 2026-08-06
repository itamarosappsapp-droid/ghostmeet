//
//  PromptFragments.swift
//  GhostMeet
//

import Foundation

/// The blocks more than one mode puts in its message, kept in one place.
///
/// Not a convenience: the heading of the screen block, the shape of the `Профиль`
/// block and the rules about what kind of question was asked are all *wording*,
/// and wording is what docs/GhostMeet-Prompts.md is authoritative about. Three
/// modes spelling «Текст с экрана (OCR):» separately is three chances to drift
/// from the document — and from each other, which is worse: the model would be
/// shown two different names for one thing depending on which chord the user
/// pressed.
///
/// The document still prints every prompt in full, and the tests compare the
/// assembled string against it. Composing from fragments is what makes the two
/// genres impossible to drift apart; the document is what keeps either of them
/// from drifting away from what is written down.
nonisolated enum PromptFragment {

    /// Heading of the block that carries what Vision read off the screen.
    /// Verbatim from docs/GhostMeet-Prompts.md §1 and §6.
    static let screenTextHeading = "Текст с экрана (OCR):"

    /// Heading the selected `Профиль` is written under — the `{{resume_context}}`
    /// slot of the prompt document, note 5.
    static let profileHeading = "Контекст о пользователе (резюме / роль / стек):"

    /// Heading the `Контекст собеседования` is written under — note 7.
    ///
    /// Named for what it is rather than "context": the app already has one
    /// «контекст», the conversation, and it is the one a hotkey clears. These are
    /// the answers the user drafted before the call, and calling them заготовки
    /// keeps the two apart in the one place where the model reads both.
    static let interviewContextHeading = "Заготовки пользователя к этому собеседованию:"

    /// Who is who in the transcript, and what one line of it means.
    ///
    /// The second sentence is not decoration. `Them` is declared as
    /// «собеседник(и)», and before turns were merged a question broken by a pause
    /// arrived as two `Them:` lines — which reads as two people, and an answer to
    /// two people is the «давай обсудим, какой вариант вам ближе» the user
    /// complained about. The merge is done by `TranscriptFormatter`; this says
    /// out loud that it was done.
    static let channels = """
    «Them» — собеседник(и), «You» — пользователь. Реплики, разорванные паузой, уже склеены: одна строка «Them: …» — это один человек и одна мысль.
    """

    /// The rule that makes a term sayable — one line, shared by every mode whose
    /// answer is read out loud (note 6).
    static let pronunciation = """
    Иностранные термины, которые пользователь будет произносить вслух, сопровождай в скобках русским произношением — тем, как это реально говорят в русскоязычной IT-среде, а не побуквенной транслитерацией: B-tree (би-три), GiST (джист), GIN (джин), nginx (энджин-икс), PostgreSQL (постгрес), Kubernetes (кубернетис). Только при первом упоминании и только там, где произношение неочевидно. Скобка — подсказка глазам: вслух произносится только сам термин, скобку читать не надо.
    """

    /// What kind of question was asked, and how each kind is answered.
    ///
    /// The classification happens **inside this request**, not in one of its own:
    /// a second round trip would cost the user a second of silence in the moment
    /// the whole product is that second. So the rules are stated and the model
    /// applies them itself, which also means the category never narrows what is
    /// sent — the same transcript, the same profile and the same заготовки go out
    /// whichever kind it turns out to be, and a misread category costs a worse
    /// answer instead of a missing one.
    ///
    /// Four kinds and not a taxonomy of ten: a long list eats the system prompt
    /// and blurs every instruction in it. Every branch has to work with nothing
    /// filled in — an unfilled `InterviewContext` is the normal case, not an
    /// error — which is why each of them says what to do without its fields
    /// rather than assuming them.
    ///
    /// Deliberately silent about *length* — that is the difference between the two
    /// genres and is set by their own rules above. Saying so is not enough on its
    /// own, though: the STAR schema in the behavioural branch **is** a statement
    /// about length, expressed as a shape, and against «максимум 3–4 строки» it
    /// reads as a contradiction. The branch therefore says outright that the
    /// schema orders the facts and the genre sets the size; otherwise a
    /// behavioural question answered briefly comes back as a story cut in half.
    static let questionKinds = """
    Определи сам, какого рода вопрос задан, и отвечай по-разному:
    - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
    - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Бери её из его заготовок, если подходящая есть, иначе строй из его роли и стека. Не выдумывай компанию, проект, срок или цифру, которых нет в контексте: без них дай честный костяк истории и оставь конкретику пользователю.
    - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну короткую нейтральную формулировку и не называй от себя ни суммы, ни факта о компании.
    - **Задача на экране** (код, алгоритм, тест, форма): считай её текущим вопросом, даже если Them ничего не спросил, и отвечай по правилам выше.
    """

    /// The screen block, or nothing at all when the screen gave up no text.
    ///
    /// The block is omitted rather than left empty on purpose: a bare heading
    /// reads to the model as "the screen is blank", which is a different — and
    /// usually wrong — statement about a screen that simply could not be grabbed.
    static func screenText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(screenTextHeading)\n\(trimmed)"
    }

    /// The system prompt with what is known about the user appended: the
    /// selected `Профиль` first, then the `Контекст собеседования`.
    ///
    /// Both are optional in the document and neither is optional here. Without
    /// the profile the model suggests experience the user does not have, which is
    /// a worse failure than a slow answer; without the заготовки the behavioural
    /// and motivation branches of `questionKinds` have nothing to answer from and
    /// fall back to generalities. An unfilled one of either adds nothing at all
    /// rather than an empty heading — a heading with nothing under it is not
    /// silence, it is a claim that there is nothing to say.
    ///
    /// The order is the order of ownership: the profile is about the person and
    /// outlives the call, the заготовки are about this call. Nothing reads them
    /// positionally, but the model sees the standing facts before the ones that
    /// change per company.
    static func system(
        _ rules: String,
        profile: UserProfile,
        interviewContext: InterviewContext = .empty
    ) -> String {
        var blocks = [rules]
        if !profile.isEmpty {
            blocks.append("\(profileHeading)\n\(profile.promptFragment)")
        }
        if !interviewContext.isEmpty {
            blocks.append("\(interviewContextHeading)\n\(interviewContext.promptFragment)")
        }
        return blocks.joined(separator: "\n\n")
    }
}
