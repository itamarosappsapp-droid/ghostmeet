//
//  AssistPromptTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// What the model is actually shown when the proactive loop fires: how much of
/// the conversation reaches it, who it thinks said what, and what it knows about
/// the user.
@Suite("Промпт режима Assist")
struct AssistPromptTests {

    // MARK: - Окно транскрипта

    @Test("Разговор идёт давно — модель видит только последние двенадцать реплик")
    func onlyTheLastTwelveTurnsReachTheModel() {
        let long = (1...20).map { number in
            spoken(.them, "вопрос-\(String(format: "%02d", number))")
        }

        let prompt = AssistPrompt.user(transcript: long)

        #expect(prompt.contains("вопрос-20"), "последняя реплика обязана быть в промпте")
        #expect(prompt.contains("вопрос-09"), "двенадцатая с конца ещё попадает в окно")
        #expect(!prompt.contains("вопрос-08"), "тринадцатая с конца уже за окном")
        #expect(transcriptLines(of: prompt).count == 12)
    }

    @Test("Реплик меньше окна — в промпт попадают все, в порядке разговора")
    func shortConversationKeepsItsOrder() {
        let call = [
            spoken(.them, "расскажите про ваш опыт"),
            spoken(.you, "семь лет на бэкенде"),
            spoken(.them, "а с конкурентностью работали?"),
        ]

        #expect(transcriptLines(of: AssistPrompt.user(transcript: call)) == [
            "Them: расскажите про ваш опыт",
            "You: семь лет на бэкенде",
            "Them: а с конкурентностью работали?",
        ])
    }

    @Test("У каждой реплики стоит метка её канала")
    func everyTurnCarriesItsChannelLabel() {
        let call = [spoken(.them, "как работает GCD?"), spoken(.you, "это очередь задач")]

        let prompt = AssistPrompt.user(transcript: call)

        #expect(prompt.contains("Them: как работает GCD?"))
        #expect(prompt.contains("You: это очередь задач"))
    }

    @Test("Реплика без распознанного текста не занимает место в окне")
    func unrecognisedTurnsAreLeftOut() {
        let call = [
            spoken(.them, "первый вопрос"),
            Turn(channel: .them, text: "", timestamp: 1, duration: 1),
            Turn(channel: .you, text: "   ", timestamp: 2, duration: 1),
            spoken(.them, "второй вопрос"),
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
            Turn(channel: .you, text: "", timestamp: 1, duration: 1),
        ]

        #expect(
            AssistPrompt.user(transcript: unrecognised)
                .contains(AssistPrompt.emptyTranscriptPlaceholder)
        )
    }

    // MARK: - Профиль

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

    private func spoken(_ channel: Channel, _ text: String) -> Turn {
        Turn(channel: channel, text: text, timestamp: 0, duration: 1)
    }

    /// Lines of the transcript block — everything that carries a channel label.
    private func transcriptLines(of prompt: String) -> [String] {
        prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You: ") }
    }
}
