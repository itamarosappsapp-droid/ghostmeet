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

    /// Who the text belongs to — the paragraph that reframes the whole answer,
    /// plus one «не так / а так» pair (note 6).
    ///
    /// **Written for a weak instruction-follower, not for a strong one.** The
    /// model the user actually runs is gpt-4o through polza.ai, and every word
    /// here answers a failure it produced live. The old rule «Пиши от первого
    /// лица, готовыми к произнесению фразами» was already in the prompt and did
    /// not work: it says nothing about *whose* first person and *who is
    /// listening*, so the model kept writing «Используйте Hash Map», which the
    /// user would then read out loud as an instruction to his own interviewer.
    ///
    /// Three properties are load-bearing and must not be "tidied away":
    ///
    /// 1. **The frame comes before the rules.** A statement about what the text
    ///    *is* (his next sentence, in his voice) sets the register; a rule buried
    ///    third in a list of ten reads as one more stylistic note.
    /// 2. **A positive pattern beats a prohibition.** Told only «не пиши в
    ///    императиве», a weak model routes around it by the letter — passive
    ///    voice, nominal sentences without a verb («Redis Sorted Set с окном —
    ///    ключи по минутам»), which is not second person and not speech either.
    /// 3. **The pair shows the register instead of describing it.** Two lines of
    ///    example did what three paragraphs of explanation had not.
    ///
    /// The example is deliberately about idempotency, *not* about the top-N
    /// question from the user's complaint. An example that answers a likely
    /// interview question turns into a template the model copies verbatim, and
    /// then any trial of the prompt measures copying rather than transfer.
    static let voice = """
    **Ты пишешь не ответ пользователю, а его собственную следующую фразу.** Через секунду он произнесёт её своим голосом вслух. Значит, это живая устная речь человека о своей работе — «я бы взял», «мы держали», «у нас это упиралось в», — а не абзац из справочника. Подлежащее — говорящий, а не слушатель. Сказуемое — глагол, а не «выполняется за», «это позволит», «рекомендуется». Исключение одно — блок кода: его не произносят, и внутри него ни первого лица, ни скобок с произношением.

    Не так — справка, её нельзя произнести:
    Используйте идемпотентный ключ на каждый платёж. Ключ рекомендуется хранить в Redis с TTL. Это позволит вам избежать дублей при повторной отправке.

    А так — речь, её произносят:
    Я вешаю на каждый платёж идемпотентный ключ и держу его в Redis (редисе) с TTL (ти-ти-эль) на сутки. Повтор тогда возвращает тот же результат, а не второе списание.
    """

    /// The rule that makes a term sayable, shared by every mode whose answer is
    /// read out loud (note 6).
    ///
    /// **Every clause here replaces one that failed on a live model.** The
    /// previous wording carried two «только» («Только при первом упоминании и
    /// только там, где произношение неочевидно») and a soothing tail («Скобка —
    /// подсказка глазам»), and out of ~14 terms in four answers exactly three got
    /// a bracket: the model read the qualifier as permission to decide for itself
    /// and decided that Redis, TTL, Postgres and O(N log N) were obvious. A
    /// reservation of the form «только там, где это уместно» is always read as
    /// permission not to comply. Hence the absolute trigger: Latin in the line →
    /// bracket, no judgement call.
    ///
    /// The three sentences after the trigger are not padding — each one repairs
    /// damage the absolute rule itself caused in trials:
    ///
    /// - «В скобке только русские буквы» — one variant produced «с фича-флагом
    ///   (feature flag)»: bracket present, contents inverted.
    /// - «Термин, написанный кириллицей, скобки не требует» — another produced
    ///   «хеш-мапу (хеш-мапа)» and «бакеты (бакеты)», pure noise.
    /// - «Есть обычное русское слово — пиши сразу по-русски» — the hard trigger
    ///   made a model *insert* English where it would have said it in Russian
    ///   («живой ecosystem (экосистема)», «рублей net (нет)»), which is worse
    ///   than the disease.
    ///
    /// The code exception is structural: `Assist` answers a screen task with a
    /// fenced block, and nobody reads an identifier out loud.
    static let pronunciation = """
    Пользователь читает твой текст вслух, поэтому каждый термин латиницей, каждая аббревиатура и каждая формула сложности получают при первом упоминании скобку с русским произношением — тем, как это говорят в русскоязычной IT-среде, а не побуквенной транслитерацией: B-tree (би-три), GiST (джист), GIN (джин), nginx (энджин-икс), PostgreSQL (постгрес), MongoDB (монго), Kubernetes (кубернетис), hash map (хеш-мапа), min-heap (мин-хип), TTL (ти-ти-эль), ZUNIONSTORE (зэт-юнион-стор), O(1) (о от единицы), O(n) (о от эн), O(log n) (о от лог эн), O(n log n) (о от эн лог эн), O(log k) (о от лог ка). Формулу читай ровно так, как она написана, и не приписывай в скобку букв, которых в ней нет. Решать, очевидно произношение или нет, не нужно: есть в строке латиница, аббревиатура или формула — есть и скобка. В скобке только русские буквы. Термин, написанный кириллицей («постгрес», «кафка»), скобки не требует: он уже произносим. Есть обычное русское слово — пиши сразу по-русски («экосистема», «на руки»), латиницу ради скобки не вставляй. В блоке кода скобок не ставь: код не произносят.
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
    ///
    /// Two branches carry a **positive sample of the answer**, and both were
    /// added because the bare prohibition failed on a live model. Told only «не
    /// выдумывай компанию, проект, срок или цифру», every trialled variant
    /// invented exactly those: «план на две недели», «релиз прошёл без
    /// даунтайма», «через полгода вынесли за пару дней». Told «не называй от
    /// себя ни суммы», three variants out of three named one — «350–450 тысяч»,
    /// «400–500 тысяч на руки», «от двухсот до двухсот пятидесяти». A ban with
    /// no pattern beside it leaves the model with nothing to produce, so it
    /// produces the plausible thing; the sample gives it something to say
    /// instead. That is why the samples must survive editing: they are the
    /// working half of these two branches, not illustration.
    ///
    /// The behavioural sample is deliberately free of any company, date, metric
    /// or outcome claim — it is what a skeleton looks like, and the model copies
    /// its *shape* along with its emptiness.
    static let questionKinds = """
    Определи сам, какого рода вопрос задан, и отвечай по-разному:
    - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
    - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Бери её из его заготовок, если подходящая есть, иначе строй костяк из его роли и стека и оставь конкретику ему, вот так: «Был случай, когда мы с коллегой разошлись по решению: я настаивал на поэтапной миграции, он — на разовом переключении. Я собрал цифры по рискам и вынес их на общий разбор, а не в личку. Сошлись на промежуточном варианте, и работать вместе это не помешало». Ни компании, ни проекта, ни срока, ни цифры, которых нет в контексте: он произнесёт это как факт о себе.
    - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну нейтральную фразу и оставь конкретику ему, вот так: «По деньгам я ориентируюсь на рынок, вилку назову, когда пойму объём задач». Ни суммы, ни срока, ни факта о компании от себя не называй.
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
