//
//  SuggestionTriggerTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Scenarios of the proactive loop, played out through the one seam of the app.
///
/// The interlocutor says something and stops; what is checked is what the user
/// would see in the window — whether a suggestion showed up at all, what text
/// grew in it, and what it said when nothing could be produced. The model is a
/// stub: none of these tests reach a network (ADR-0003).
@Suite("Автоподсказка по реплике Them")
@MainActor
struct SuggestionTriggerTests {

    // MARK: - Что запускает подсказку

    @Test("Собеседник договорил и замолчал — подсказка запустилась сама")
    func themTurnStartsSuggestion() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(.fragments(["Расскажу ", "про миграцию."])),
            recognisesAs: "расскажите про ваш опыт"
        )

        call.says(.them)
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1, "реплика Them должна была запустить подсказку")
        #expect(call.engine.suggestions.first?.text == "Расскажу про миграцию.")
        #expect(call.engine.suggestions.first?.state == .complete)
        #expect(call.provider.requests.count == 1, "к модели должен был уйти ровно один запрос")
    }

    @Test("Реплику договорил сам пользователь — ничего не запускается")
    func youTurnStartsNothing() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(),
            recognisesAs: "я работал в основном с бэкендом"
        )

        call.says(.you)
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.map(\.channel) == [.you], "реплика должна была попасть в транскрипт")
        #expect(call.engine.suggestions.isEmpty, "собственная речь подсказку не запрашивает")
        #expect(call.provider.requests.isEmpty, "к модели не должно было уйти ничего")
    }

    @Test("Заговорил собеседник — подсказка появилась и на его реплику, и только на неё")
    func onlyThemTurnsAskForSuggestions() async {
        let call = SuggestionCall(provider: StubLLMProvider(), recognisesAs: "ага")

        call.says(.you)
        call.says(.them)
        call.says(.you)
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.map(\.channel) == [.you, .them, .you])
        #expect(call.engine.suggestions.count == 1, "подсказка ровно одна — на единственную реплику Them")
        #expect(call.engine.suggestions.first?.promptedBy == call.engine.transcript[1].id)
    }

    // MARK: - Стриминг

    @Test("Ответ печатается по мере генерации, а не появляется целиком в конце")
    func fragmentsArriveOneByOne() async {
        let provider = StubLLMProvider(.manual)
        let call = SuggestionCall(provider: provider, recognisesAs: "оцените сложность решения")

        call.says(.them)
        await call.engine.waitForRecognition()

        #expect(call.engine.suggestions.count == 1, "подсказка должна появиться до первого фрагмента")
        #expect(call.engine.suggestions.first?.text.isEmpty == true)
        #expect(call.engine.suggestions.first?.state == .streaming)

        provider.emit("Сейчас это ")
        #expect(await call.textOfLatestReaches("Сейчас это "), "первый фрагмент должен быть виден сразу")
        #expect(call.engine.suggestions.first?.state == .streaming, "подсказка ещё пишется")

        provider.emit("O(n²).")
        #expect(await call.textOfLatestReaches("Сейчас это O(n²)."), "второй фрагмент дописывается к первому")

        provider.finish()
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.first?.state == .complete)
        #expect(call.engine.suggestions.first?.text == "Сейчас это O(n²).")
    }

    // MARK: - Ошибки

    @Test("Провайдер отказал — это состояние подсказки, а не падение сессии")
    func providerFailureBecomesFailedSuggestion() async {
        let call = SuggestionCall(
            provider: StubLLMProvider(.failure(LLMFailure.unauthorized)),
            recognisesAs: "первый вопрос"
        )

        call.says(.them)
        await call.engine.waitForSuggestion()

        #expect(call.engine.suggestions.count == 1)
        #expect(call.engine.suggestions.first?.state == .failed(LLMFailure.unauthorized.message))

        // Разговор продолжается: следующая реплика собеседника снова просит
        // подсказку, а не упирается в предыдущий сбой.
        call.says(.them)
        await call.engine.waitForSuggestion()

        #expect(call.engine.transcript.count == 2)
        #expect(call.engine.suggestions.count == 2, "сбой не должен был остановить цикл")
    }

    @Test("Ключа нет — в ленте видна причина словами, а не пустая карточка")
    func failureCarriesItsReasonIntoTheFeed() async {
        let call = SuggestionCall(provider: StubLLMProvider(.failure(LLMFailure.missingKey)))

        call.says(.them)
        await call.engine.waitForSuggestion()

        guard case .failed(let message) = call.engine.suggestions.first?.state else {
            Issue.record("подсказка должна была перейти в состояние failed")
            return
        }
        #expect(message == "Не задан ключ провайдера — откройте настройки.")
    }

    // MARK: - Пустой транскрипт

    @Test("Ничего ещё не распознано — запрос всё равно уходит, с подстановкой вместо разговора")
    func emptyTranscriptStillMakesARequest() async {
        // Распознавание вернуло пустую строку: реплика в транскрипте есть, слов в ней нет.
        let call = SuggestionCall(provider: StubLLMProvider(.fragments(["Готов помочь."])))

        call.says(.them)
        await call.engine.waitForSuggestion()

        let request = call.provider.requests.first
        #expect(request?.userPrompt.contains(AssistPrompt.emptyTranscriptPlaceholder) == true)
        #expect(request?.maxTokens == AssistPrompt.maxTokens)
        #expect(call.engine.suggestions.first?.text == "Готов помочь.", "подсказка всё равно должна прийти")
        #expect(call.engine.suggestions.first?.state == .complete)
    }

    @Test("Разговор уже идёт — в запрос уходят реплики с метками каналов")
    func transcriptReachesTheRequest() async {
        let call = SuggestionCall(provider: StubLLMProvider(), recognisesAs: "какой у вас стек")

        call.says(.them)
        await call.engine.waitForSuggestion()

        let prompt = call.provider.requests.first?.userPrompt ?? ""
        #expect(prompt.contains("Them: какой у вас стек"))
        #expect(
            !prompt.contains(AssistPrompt.emptyTranscriptPlaceholder),
            "подстановка нужна только там, где разговора нет"
        )
    }
}

// MARK: - Обстановка звонка

/// A call whose model is a stub: speech goes in, requests and suggestions come out.
///
/// Mirrors `CallFixture`, with the model plugged in — the other suite has no
/// provider and must keep working without one.
@MainActor
private struct SuggestionCall {
    let engine: SessionEngine
    let provider: StubLLMProvider

    private let clock: ManualClock
    private let frameLength: TimeInterval = 0.1

    init(
        provider: StubLLMProvider,
        recognisesAs text: String = "",
        profile: UserProfile = .empty
    ) {
        let clock = ManualClock()
        self.clock = clock
        self.provider = provider
        self.engine = SessionEngine(
            recognizer: RecognizerSpy(reply: text),
            provider: provider,
            composer: AssistSuggestionComposer { profile },
            clock: clock
        )
    }

    /// A whole turn of one channel: someone talks, then stops long enough for
    /// the turn to close.
    func says(_ channel: Channel, for seconds: TimeInterval = 1.2) {
        feed(seconds: seconds) { AudioFrames.speech(channel: channel, duration: frameLength) }
        feed(seconds: 0.9) { AudioFrames.silence(channel: channel, duration: frameLength) }
    }

    /// Waits until the newest suggestion has grown to `text`.
    ///
    /// Fragments cross a task boundary, so they land a hop later rather than
    /// instantly; the loop is bounded so a stalled stream fails the test instead
    /// of hanging it.
    func textOfLatestReaches(_ text: String, within timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if engine.suggestions.last?.text == text { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    private func feed(seconds: TimeInterval, frame: () -> AudioFrame) {
        let frames = Int((seconds / frameLength).rounded())
        for _ in 0..<frames {
            clock.advance(by: frameLength)
            engine.ingest(frame())
        }
    }
}

// MARK: - Модель-заглушка

/// A model that answers from a script and remembers what it was asked.
///
/// `manual` exists for the one thing a scripted answer cannot show: that the
/// text appears in the window while the model is still writing it.
private final class StubLLMProvider: LLMProvider, @unchecked Sendable {

    enum Script {
        /// Yields every fragment, then finishes.
        case fragments([String])
        /// Refuses straight away.
        case failure(any Error)
        /// The test yields the fragments by hand.
        case manual
    }

    let name = "Заглушка"
    let capabilities = ProviderCapabilities.multimodal

    private let lock = NSLock()
    private let script: Script
    private var recorded: [SuggestionRequest] = []
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

    init(_ script: Script = .fragments(["готово"])) {
        self.script = script
    }

    /// Requests that actually reached the model, in order.
    var requests: [SuggestionRequest] {
        lock.withLock { recorded }
    }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            switch script {
            case .fragments(let parts):
                for part in parts { continuation.yield(part) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .manual:
                break
            }
        }
    }

    /// Writes one more fragment of the answer.
    func emit(_ fragment: String) {
        lock.withLock { continuation }?.yield(fragment)
    }

    /// The model finished writing.
    func finish() {
        lock.withLock { continuation }?.finish()
    }
}
