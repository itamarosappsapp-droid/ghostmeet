//
//  BriefPromptTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What the model is shown for the жанр «коротко» — the default press.
///
/// The rules this suite guards are not style. Each of them is a failure seen on a
/// recording of a real interview: an answer that started over from the beginning
/// while the candidate was already three sentences in, and an answer that ended
/// with «давай обсудим, какой из вариантов подходит больше» — a suggestion that
/// is read out loud whole, addressed to the interviewer.
@Suite("Промпт короткого жанра")
struct BriefPromptTests {

    // MARK: - Текст промпта

    @Test("Системная часть слово в слово повторяет документ промптов, §9")
    func theSystemPromptMatchesTheDocument() {
        #expect(BriefPrompt.system(profile: .empty) == """
        Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка.

        «Them» — собеседник(и), «You» — пользователь. Реплики, разорванные паузой, уже склеены: одна строка «Them: …» — это один человек и одна мысль.

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
        - Иностранные термины, которые пользователь будет произносить вслух, сопровождай в скобках русским произношением — тем, как это реально говорят в русскоязычной IT-среде, а не побуквенной транслитерацией: B-tree (би-три), GiST (джист), GIN (джин), nginx (энджин-икс), PostgreSQL (постгрес), Kubernetes (кубернетис). Только при первом упоминании и только там, где произношение неочевидно. Скобка — подсказка глазам: вслух произносится только сам термин, скобку читать не надо.
        - Язык ответа — язык разговора (обычно русский или английский).

        Определи сам, какого рода вопрос задан, и отвечай по-разному:
        - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
        - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Бери её из его заготовок, если подходящая есть, иначе строй из его роли и стека. Не выдумывай компанию, проект, срок или цифру, которых нет в контексте: без них дай честный костяк истории и оставь конкретику пользователю.
        - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну короткую нейтральную формулировку и не называй от себя ни суммы, ни факта о компании.
        - **Задача на экране** (код, алгоритм, тест, форма): считай её текущим вопросом, даже если Them ничего не спросил, и отвечай по правилам выше.
        """)
    }

    @Test("Модели сказано, зачем нажали: не знает или сомневается — и уже отвечает")
    func theModelIsToldWhyThePressHappened() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("не знает, не помнит или сомневается"))
        #expect(system.contains("уже начал отвечать вслух"))
        #expect(
            system.contains("не ответа с начала"),
            "иначе модель начинает объяснять тему заново, пока человек уже говорит"
        )
    }

    @Test("Запреты на диалоговые обороты стоят прямо в правилах")
    func theProhibitionsAreSpelledOut() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("Не обращайся к собеседнику"))
        #expect(system.contains("не предлагай что-то обсудить"))
        #expect(system.contains("не задавай встречных вопросов"))
        #expect(system.contains("не предлагай несколько вариантов на выбор"))
    }

    @Test("Причина запретов названа до них: текст произнесут целиком, как свою реплику")
    func theProhibitionsRestOnOneStatedReason() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("Твой текст он произнесёт целиком, как свою реплику."))
        #expect(system.contains("он читает вслух"))
        #expect(
            system.contains("Не пиши, что чего-то не знаешь"),
            "оговорка «данных мало» тоже будет произнесена вслух"
        )
    }

    @Test("Один канал — один человек: модели сказано, что реплики уже склеены")
    func theModelIsToldThatTurnsAreMerged() {
        #expect(
            BriefPrompt.system(profile: .empty)
                .contains("одна строка «Them: …» — это один человек и одна мысль"),
            "без этого разорванный вопрос читается как дискуссия нескольких людей"
        )
    }

    @Test("Правило произношения терминов пережило правку")
    func thePronunciationRuleSurvives() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("GiST (джист)"))
        #expect(system.contains("Только при первом упоминании"))
    }

    @Test("Язык ответа не форсируется: правило отсылает к языку разговора")
    func answerLanguageFollowsTheConversation() {
        #expect(BriefPrompt.system(profile: .empty).contains("Язык ответа — язык разговора"))
    }

    // MARK: - Роды вопросов

    @Test("Правила различают роды вопросов и говорят, как отвечать на каждый")
    func theRulesTellTheKindsOfQuestionApart() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("Определи сам, какого рода вопрос задан"))
        #expect(system.contains("**Технический**"))
        #expect(system.contains("**Про опыт и поведение**"))
        #expect(system.contains("**Про компанию, мотивацию и условия**"))
        #expect(system.contains("**Задача на экране**"))
    }

    @Test("Технический вопрос отвечается механикой, без биографии")
    func technicalQuestionsGetMechanicsAndNoBiography() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("механика по существу"))
        #expect(system.contains("Биографию сюда не подмешивай"))
    }

    @Test("Поведенческий вопрос отвечается историей пользователя по схеме, а не абстракцией")
    func behaviouralQuestionsGetTheUsersOwnStory() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("ситуация — задача — что сделал — результат"))
        #expect(system.contains("Бери её из его заготовок"))
        #expect(
            system.contains("Не выдумывай компанию, проект, срок или цифру"),
            "выдуманный проект в ответе кандидата — худший из возможных исходов"
        )
    }

    @Test("Вопросы о компании и деньгах отвечаются заготовками, а не выдумкой")
    func motivationQuestionsAreAnsweredFromThePreparedFields() {
        let system = BriefPrompt.system(profile: .empty)

        #expect(system.contains("отвечай заготовками пользователя к этому собеседованию"))
        #expect(system.contains("не называй от себя ни суммы, ни факта о компании"))
    }

    @Test("Ни одна ветка не требует заполненных полей: пустой контекст — обычное дело")
    func everyBranchWorksWithNothingFilledIn() {
        let system = BriefPrompt.system(profile: .empty, interviewContext: .empty)

        // Правила на месте целиком, хотя ни профиля, ни заготовок нет …
        #expect(system.contains("**Про опыт и поведение**"))
        #expect(system.contains("**Про компанию, мотивацию и условия**"))
        // … и каждая ветка сама говорит, что делать без них.
        #expect(system.contains("иначе строй из его роли и стека"))
        #expect(system.contains("Нужной заготовки нет — дай одну короткую нейтральную формулировку"))
        #expect(!system.contains(PromptFragment.interviewContextHeading), "пустого блока быть не должно")
    }

    @Test("Категория ничего не сужает: второго запроса к модели не появляется")
    func theCategoryCostsNoSecondRequest() {
        let transcript = [Turn(channel: .them, text: "расскажите про конфликт", timestamp: 0, duration: 1)]
        let context = InterviewContext(stories: "Спор о схеме БД", compensation: "от 400")

        let request = BriefPrompt.request(
            transcript: transcript,
            profile: UserProfile(role: "Тимлид"),
            interviewContext: context
        )

        // Один запрос, и в нём всё: разговор, профиль, все четыре заготовки —
        // отбор по категории не делается, ошибка отбора стоила бы ответа.
        #expect(request.userPrompt.contains("Them: расскажите про конфликт"))
        #expect(request.systemPrompt.contains("Роль: Тимлид"))
        #expect(request.systemPrompt.contains("Спор о схеме БД"))
        #expect(request.systemPrompt.contains("от 400"))
    }

    // MARK: - Бюджет

    @Test("Бюджет — из короткой полосы и заметно ниже развёрнутого жанра")
    func theBudgetIsTheShortBand() {
        #expect((256...512).contains(BriefPrompt.maxTokens))
        #expect(
            BriefPrompt.maxTokens < AssistPrompt.maxTokens,
            "бюджет, позволяющий сочинение, сочинение и получит"
        )
        #expect(BriefPrompt.request(transcript: [], profile: .empty).maxTokens == BriefPrompt.maxTokens)
    }

    // MARK: - Окно транскрипта

    @Test("Окно накрывает весь звонок: реплика получасовой давности всё ещё в промпте")
    func thewholeCallReachesTheModel() {
        let call = (1...200).map { number in
            spoken(.them, "вопрос-\(String(format: "%03d", number))", at: Double(number) * 10)
        }

        let prompt = BriefPrompt.user(transcript: call)

        #expect(BriefPrompt.transcriptWindow == TranscriptFormatter.wholeCall)
        #expect(prompt.contains("вопрос-200"))
        #expect(prompt.contains("вопрос-001"), "начало звонка Summarizer больше не съедает — его нет")
    }

    @Test("У каждой реплики стоит метка её канала")
    func everyTurnCarriesItsChannelLabel() {
        let prompt = BriefPrompt.user(
            transcript: [spoken(.them, "как работает GCD?", at: 0), spoken(.you, "это очередь задач", at: 10)]
        )

        #expect(prompt.contains("Them: как работает GCD?"))
        #expect(prompt.contains("You: это очередь задач"))
    }

    @Test("Две половинки вопроса приходят в промпт одной строкой")
    func aQuestionSplitByAPauseArrivesWhole() {
        let prompt = BriefPrompt.user(
            transcript: [
                spoken(.them, "а как вы", at: 0),
                spoken(.them, "это масштабировали?", at: 2.5),
            ]
        )

        #expect(prompt.contains("Them: а как вы это масштабировали?"))
    }

    // MARK: - Пустой транскрипт и экран

    @Test("Разговор ещё не записан — вместо пустого заголовка стоит подстановка")
    func anEmptyTranscriptGetsAPlaceholder() {
        let prompt = BriefPrompt.user(transcript: [])

        #expect(prompt.contains(BriefPrompt.emptyTranscriptPlaceholder))
        #expect(
            !prompt.contains("Разговор:\n\n"),
            "голый заголовок читается моделью как «никто ничего не сказал»"
        )
        #expect(prompt.hasSuffix("Я уже отвечаю. Дай то, чего мне не хватает."))
    }

    @Test("Экран ничего не отдал — блока OCR нет вовсе")
    func anEmptyScreenAddsNoBlock() {
        #expect(!BriefPrompt.user(transcript: [], screenText: "   ").contains(BriefPrompt.screenTextHeading))
    }

    @Test("Текст с экрана уходит своим блоком, тем же заголовком, что и у остальных режимов")
    func theScreenTextTravelsInItsOwnBlock() {
        let prompt = BriefPrompt.user(transcript: [], screenText: "func reverse(_ list: [Int])")

        #expect(prompt.contains(BriefPrompt.screenTextHeading))
        #expect(prompt.contains("func reverse(_ list: [Int])"))
        #expect(BriefPrompt.screenTextHeading == AssistPrompt.screenTextHeading, "одна вещь — одно имя")
    }

    // MARK: - Профиль и заготовки

    @Test("Профиль пользователя дописан в конец системной части")
    func profileLandsInTheSystemPrompt() {
        let system = BriefPrompt.system(
            profile: UserProfile(role: "Senior iOS Engineer", stack: "Swift, Core Audio")
        )

        #expect(system.contains("Контекст о пользователе (резюме / роль / стек):"))
        #expect(system.contains("Роль: Senior iOS Engineer"))
        #expect(system.hasSuffix("Стек: Swift, Core Audio"), "профиль идёт последним, когда заготовок нет")
    }

    @Test("Профиль не заполнен — пустого блока в системной части нет")
    func emptyProfileAddsNothing() {
        #expect(!BriefPrompt.system(profile: .empty).contains("Контекст о пользователе"))
    }

    @Test("Заготовки к собеседованию идут в system рядом с профилем, а не вместо него")
    func theInterviewContextTravelsBesideTheProfile() {
        let system = BriefPrompt.system(
            profile: UserProfile(role: "Тимлид", stack: "Go, Postgres"),
            interviewContext: InterviewContext(
                stories: "Разнял спор о схеме БД: развели миграции по фичам, релиз не сдвинулся.",
                motivation: "Иду в платформенную команду — там мой профиль."
            )
        )

        #expect(system.contains("Роль: Тимлид"), "профиль на месте")
        #expect(system.contains(PromptFragment.interviewContextHeading))
        #expect(system.contains("Истории из практики:\nРазнял спор о схеме БД"))
        #expect(system.contains("Почему эта компания:\nИду в платформенную команду"))
        #expect(!system.contains("Ожидания по деньгам"), "незаполненное поле не даёт даже подписи")
        #expect(
            system.range(of: "Контекст о пользователе")!.lowerBound
                < system.range(of: PromptFragment.interviewContextHeading)!.lowerBound,
            "сначала кто человек, потом что он приготовил к этому звонку"
        )
    }

    @Test("Заготовки не заполнены — пустого блока в системной части нет")
    func anEmptyInterviewContextAddsNothing() {
        #expect(
            BriefPrompt.system(profile: .empty, interviewContext: .empty)
                == BriefPrompt.system(profile: .empty, interviewContext: InterviewContext(stories: "  \n "))
        )
        #expect(
            !BriefPrompt.system(profile: .empty).contains(PromptFragment.interviewContextHeading)
        )
    }

    @Test("Скриншот прикладывается к запросу как есть")
    func screenshotIsCarriedIntoTheRequest() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        #expect(BriefPrompt.request(transcript: [], profile: .empty, screenshot: png).screenshot == png)
    }

    // MARK: - Хелперы

    private func spoken(_ channel: Channel, _ text: String, at timestamp: TimeInterval) -> Turn {
        Turn(channel: channel, text: text, timestamp: timestamp, duration: 1)
    }
}
