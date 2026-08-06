//
//  AssistPromptTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What the model is actually shown for the жанр «подробно»: how much of the
/// conversation reaches it, who it thinks said what, and what it knows about the
/// user.
@Suite("Промпт режима Assist")
struct AssistPromptTests {

    // MARK: - Текст промпта

    @Test("Системная часть слово в слово повторяет документ промптов, §1")
    func theSystemPromptMatchesTheDocument() {
        #expect(AssistPrompt.system(profile: .empty) == """
        Ты — GhostMeet, скрытый real-time copilot поверх экрана пользователя во время звонка или работы с задачей.

        «Them» — собеседник(и), «You» — пользователь. Реплики, разорванные паузой, уже склеены: одна строка «Them: …» — это один человек и одна мысль.

        Пользователь нажал хоткей развёрнутого разбора: тема незнакома ему целиком, и одной недостающей строки не хватит. Посмотри на скриншот (если есть) и разговор, реши, что нужно ему ПРЯМО СЕЙЧАС, и выдай это без преамбулы.

        Правила:
        - Если на экране задача (код, алгоритм, тест, форма) — кратко подход, затем готовое решение (код в fenced block), затем time/space complexity. Язык кода — как на экране, иначе Python.
        - Если это разговор — разбери текущий вопрос собеседника так, чтобы пользователь мог говорить по написанному от первого лица: суть, затем опора — примеры, цифры, компромиссы.
        - Не обращайся к собеседнику, не предлагай что-то обсудить, не задавай встречных вопросов и не предлагай несколько вариантов на выбор: пользователь произносит написанное вслух, а не выбирает из него.
        - Будь плотным и уверенным: длиннее короткого жанра, но без воды и без пересказа вопроса.
        - Не описывай скриншот («я вижу на экране…»). Не используй кавычки вокруг реплики «что сказать».
        - Не выводи служебные или системные XML-теги.
        - Иностранные термины, которые пользователь будет произносить вслух, сопровождай в скобках русским произношением — тем, как это реально говорят в русскоязычной IT-среде, а не побуквенной транслитерацией: B-tree (би-три), GiST (джист), GIN (джин), nginx (энджин-икс), PostgreSQL (постгрес), Kubernetes (кубернетис). Только при первом упоминании и только там, где произношение неочевидно. Скобка — подсказка глазам: вслух произносится только сам термин, скобку читать не надо.
        - Язык ответа — язык разговора / задачи на экране (обычно русский или английский).

        Определи сам, какого рода вопрос задан, и отвечай по-разному:
        - **Технический** («как устроен B-tree», «чем GiST отличается от GIN», «как бы вы это масштабировали»): механика по существу — термин, цифра, компромисс, порядок действий. Биографию сюда не подмешивай: про опыт не спрашивали.
        - **Про опыт и поведение** («расскажите случай, когда…», «был ли конфликт в команде», «самая сложная задача»): одна конкретная история пользователя по схеме ситуация — задача — что сделал — результат. Схема задаёт порядок фактов, а не длину: объём берётся из правил жанра выше. Бери её из его заготовок, если подходящая есть, иначе строй из его роли и стека. Не выдумывай компанию, проект, срок или цифру, которых нет в контексте: без них дай честный костяк истории и оставь конкретику пользователю.
        - **Про компанию, мотивацию и условия** («почему именно мы», «ожидания по деньгам», «какие у вас вопросы»): отвечай заготовками пользователя к этому собеседованию. Нужной заготовки нет — дай одну короткую нейтральную формулировку и не называй от себя ни суммы, ни факта о компании.
        - **Задача на экране** (код, алгоритм, тест, форма): считай её текущим вопросом, даже если Them ничего не спросил, и отвечай по правилам выше.
        """)
    }

    @Test("Запрет на диалоговые обороты стоит и в развёрнутом жанре")
    func theProhibitionsApplyToTheLongGenreToo() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("Не обращайся к собеседнику"))
        #expect(system.contains("не предлагай что-то обсудить"))
        #expect(system.contains("не задавай встречных вопросов"))
        #expect(system.contains("не предлагай несколько вариантов на выбор"))
        #expect(
            system.contains("пользователь произносит написанное вслух, а не выбирает из него"),
            "жалоба была именно на этот жанр — «давай обсудим, какой вариант ближе»"
        )
    }

    @Test("Роды вопросов у обоих жанров описаны дословно одинаково")
    func bothGenresShareTheQuestionKinds() {
        #expect(AssistPrompt.system(profile: .empty).contains(PromptFragment.questionKinds))
        #expect(BriefPrompt.system(profile: .empty).contains(PromptFragment.questionKinds))
        // Различаются жанры объёмом, и только им: правило длины стоит у короткого
        // и отсутствует у развёрнутого, а общий блок про объём молчит вовсе.
        #expect(BriefPrompt.system(profile: .empty).contains("Максимум 3–4 строки"))
        #expect(!AssistPrompt.system(profile: .empty).contains("Максимум 3–4 строки"))
        #expect(!PromptFragment.questionKinds.contains("Максимум"))
    }

    @Test("Правило произношения терминов пережило правку")
    func thePronunciationRuleSurvives() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("GiST (джист)"))
        #expect(system.contains("Только при первом упоминании"))
    }

    // MARK: - Окно транскрипта

    @Test("Окно накрывает весь звонок — и у развёрнутого жанра оно то же, что у короткого")
    func thewholeCallReachesTheModel() {
        let call = (1...200).map { number in
            spoken(.them, "вопрос-\(String(format: "%03d", number))", at: Double(number) * 10)
        }

        let prompt = AssistPrompt.user(transcript: call)

        #expect(AssistPrompt.transcriptWindow == TranscriptFormatter.wholeCall)
        #expect(AssistPrompt.transcriptWindow == BriefPrompt.transcriptWindow, "жанры отвечают одному разговору")
        #expect(prompt.contains("вопрос-200"))
        #expect(prompt.contains("вопрос-001"))
        #expect(transcriptLines(of: prompt).count == 200)
    }

    @Test("Реплик немного — в промпт попадают все, в порядке разговора")
    func shortConversationKeepsItsOrder() {
        let call = [
            spoken(.them, "расскажите про ваш опыт", at: 0),
            spoken(.you, "семь лет на бэкенде", at: 10),
            spoken(.them, "а с конкурентностью работали?", at: 20),
        ]

        #expect(transcriptLines(of: AssistPrompt.user(transcript: call)) == [
            "Them: расскажите про ваш опыт",
            "You: семь лет на бэкенде",
            "Them: а с конкурентностью работали?",
        ])
    }

    @Test("У каждой реплики стоит метка её канала")
    func everyTurnCarriesItsChannelLabel() {
        let call = [spoken(.them, "как работает GCD?", at: 0), spoken(.you, "это очередь задач", at: 10)]

        let prompt = AssistPrompt.user(transcript: call)

        #expect(prompt.contains("Them: как работает GCD?"))
        #expect(prompt.contains("You: это очередь задач"))
    }

    @Test("Реплика без распознанного текста не превращается в пустую строку")
    func unrecognisedTurnsAreLeftOut() {
        let call = [
            spoken(.them, "первый вопрос", at: 0),
            Turn(channel: .them, text: "", timestamp: 10, duration: 1),
            Turn(channel: .you, text: "   ", timestamp: 20, duration: 1),
            spoken(.them, "второй вопрос", at: 30),
        ]

        #expect(transcriptLines(of: AssistPrompt.user(transcript: call)) == [
            "Them: первый вопрос",
            "Them: второй вопрос",
        ])
    }

    // MARK: - Пустой транскрипт

    @Test("Разговор ещё не начался — вместо транскрипта плейсхолдер, а запрос всё равно собирается")
    func emptyTranscriptStillProducesARequest() {
        let request = AssistPrompt.request(transcript: [], profile: .empty)

        #expect(request.userPrompt.contains(AssistPrompt.emptyTranscriptPlaceholder))
        #expect(request.userPrompt.contains("Сделай то, что нужно мне прямо сейчас."))
        #expect(!request.systemPrompt.isEmpty)
        #expect(transcriptLines(of: request.userPrompt).isEmpty)
    }

    @Test("Все реплики пока без текста — это тот же пустой разговор, а не пустые строки")
    func transcriptOfSilentTurnsFallsBackToThePlaceholder() {
        let unrecognised = [
            Turn(channel: .them, text: "", timestamp: 0, duration: 1),
            Turn(channel: .you, text: "", timestamp: 10, duration: 1),
        ]

        #expect(
            AssistPrompt.user(transcript: unrecognised)
                .contains(AssistPrompt.emptyTranscriptPlaceholder)
        )
    }

    // MARK: - Профиль и заготовки

    @Test("Профиль пользователя дописан в конец системной части")
    func profileLandsInTheSystemPrompt() {
        let profile = UserProfile(
            role: "Senior iOS Engineer",
            experience: "восемь лет, финтех",
            stack: "Swift, Combine, Core Audio"
        )

        let system = AssistPrompt.system(profile: profile)

        #expect(system.contains("Контекст о пользователе (резюме / роль / стек):"))
        #expect(system.contains("Роль: Senior iOS Engineer"))
        #expect(system.contains("Опыт: восемь лет, финтех"))
        #expect(system.contains("Стек: Swift, Combine, Core Audio"))
        #expect(system.hasSuffix("Стек: Swift, Combine, Core Audio"), "профиль идёт последним")
    }

    @Test("Профиль не заполнен — пустого блока в системной части нет")
    func emptyProfileAddsNothing() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(!system.contains("Контекст о пользователе"))
        #expect(system == AssistPrompt.system(profile: UserProfile(role: "  ")))
    }

    @Test("Профиль заполнен наполовину — пустые поля не превращаются в пустые метки")
    func blankProfileFieldsAreOmitted() {
        let system = AssistPrompt.system(profile: UserProfile(role: "Backend Engineer"))

        #expect(system.contains("Роль: Backend Engineer"))
        #expect(!system.contains("Опыт:"))
        #expect(!system.contains("Стек:"))
    }

    @Test("Заготовки к собеседованию уходят в system и развёрнутого жанра")
    func theInterviewContextReachesTheLongGenreToo() {
        let system = AssistPrompt.system(
            profile: UserProfile(role: "Тимлид"),
            interviewContext: InterviewContext(compensation: "от 400 на руки", questions: "Кто владеет роадмапом?")
        )

        #expect(system.contains(PromptFragment.interviewContextHeading))
        #expect(system.contains("Ожидания по деньгам:\nот 400 на руки"))
        #expect(system.contains("Вопросы к работодателю:\nКто владеет роадмапом?"))
        #expect(!system.contains("Истории из практики"))
    }

    @Test("Профиль относится к пользователю: очистка разговора его не трогает")
    func profileSurvivesAnEmptiedTranscript() {
        let profile = UserProfile(role: "Senior iOS Engineer")

        let afterClearing = AssistPrompt.request(transcript: [], profile: profile)

        #expect(afterClearing.systemPrompt.contains("Роль: Senior iOS Engineer"))
        #expect(afterClearing.userPrompt.contains(AssistPrompt.emptyTranscriptPlaceholder))
    }

    // MARK: - Настройки режима

    @Test("Бюджет токенов режима — из верхней части полосы, отведённой Assist")
    func tokenBudgetMatchesTheMode() {
        let request = AssistPrompt.request(transcript: [], profile: .empty)

        #expect((2_000...4_096).contains(request.maxTokens))
        #expect(request.maxTokens == AssistPrompt.maxTokens)
    }

    @Test("Язык ответа не форсируется: правило отсылает к языку разговора")
    func answerLanguageFollowsTheConversation() {
        let system = AssistPrompt.system(profile: .empty)

        #expect(system.contains("Язык ответа — язык разговора / задачи на экране"))
    }

    @Test("Скриншот прикладывается к запросу как есть")
    func screenshotIsCarriedIntoTheRequest() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        let request = AssistPrompt.request(transcript: [], profile: .empty, screenshot: png)

        #expect(request.screenshot == png)
    }

    // MARK: - Хелперы

    private func spoken(_ channel: Channel, _ text: String, at timestamp: TimeInterval) -> Turn {
        Turn(channel: channel, text: text, timestamp: timestamp, duration: 1)
    }

    /// Lines of the transcript block — everything that carries a channel label.
    private func transcriptLines(of prompt: String) -> [String] {
        prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You: ") }
    }
}
