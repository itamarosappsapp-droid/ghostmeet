//
//  SessionEngineTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Scenarios of a call, played out through the one seam of the app: audio goes
/// into `SessionEngine`, the clock is moved by hand, and what is checked is what
/// the user sees — which turns ended up in the transcript.
@Suite("Нарезка речи на реплики")
@MainActor
struct SessionEngineTests {

    // MARK: - Пауза

    @Test("Говорящий замолчал на 1,6 с — реплика закрылась")
    func pauseAboveThresholdClosesTurn() {
        let call = CallFixture()

        call.someoneSpeaks(for: 1.5)
        call.silenceLasts(1.6)

        #expect(call.transcript.count == 1)
        #expect(call.transcript.first?.duration.isClose(to: 1.5) == true)
    }

    @Test("Собеседник задумался на 1,2 с посреди вопроса — вопрос не разорвался")
    func pauseBelowThresholdKeepsTurnOpen() {
        let call = CallFixture()

        call.someoneSpeaks(for: 1.0)
        call.silenceLasts(1.2)
        call.someoneSpeaks(for: 1.0)

        #expect(call.transcript.isEmpty, "реплика ещё не должна была закрыться")

        call.silenceLasts(1.6)

        // Ровно то, ради чего порог подняли: паузы на границе придаточного идут
        // 1,0–1,5 с, и на старых 800 мс каждая такая резала вопрос надвое.
        #expect(call.transcript.count == 1, "пауза на раздумье не должна была разрезать вопрос")
        #expect(call.transcript.first?.duration.isClose(to: 3.2) == true)
    }

    // MARK: - Гейт тишины и минимальная длина

    @Test("В комнате тихо — реплик нет и распознавание не запускается")
    func silenceNeverBecomesATurn() async {
        let call = CallFixture()

        call.silenceLasts(5.0)
        await call.engine.waitForRecognition()

        #expect(call.transcript.isEmpty)
        let requests = await call.recognizer.requests
        #expect(requests.isEmpty, "тишина не должна доходить до распознавания")
    }

    @Test("Кашлянул на 300 мс — слишком коротко, чтобы стать репликой")
    func tooShortSoundNeverBecomesATurn() async {
        let call = CallFixture()

        call.someoneSpeaks(for: 0.3)
        call.silenceLasts(1.6)
        await call.engine.waitForRecognition()

        #expect(call.transcript.isEmpty)
        let requests = await call.recognizer.requests
        #expect(requests.isEmpty, "обрывок короче минимальной длины не должен распознаваться")
    }

    // MARK: - Страховочный флаш

    @Test("Собеседник говорит без пауз — реплика всё равно попадает в транскрипт")
    func monologueIsFlushedWithoutAnyPause() {
        let call = CallFixture()

        call.someoneSpeaks(for: 10.5, on: .them)

        #expect(call.transcript.count == 1, "монолог должен был закрыться страховочным флашем")
        // Флаш срабатывает на ближайшей границе кадра, поэтому реплика выходит
        // чуть длиннее порога — но именно порядка десяти секунд, а не всей речи.
        #expect(call.transcript.first?.duration.isClose(to: 10.0, tolerance: 0.15) == true)

        call.someoneSpeaks(for: 1.5, on: .them)

        #expect(call.transcript.count == 1, "следующая часть монолога ещё не дозрела до флаша")
    }

    // MARK: - Конфигурация и часы

    @Test("Пороги пришли из конфигурации: с быстрыми настройками короткая фраза стала репликой")
    func thresholdsComeFromConfiguration() {
        let impatient = TurnSegmentationConfig(
            pauseThreshold: 0.3,
            minimumTurnDuration: 0.2
        )
        let quickCall = CallFixture(config: impatient)
        let defaultCall = CallFixture()

        for call in [quickCall, defaultCall] {
            call.someoneSpeaks(for: 0.4)
            call.silenceLasts(0.4)
        }

        #expect(quickCall.transcript.count == 1, "с порогом 300 мс фраза должна была закрыться")
        #expect(defaultCall.transcript.isEmpty, "с порогами по умолчанию она ещё не реплика")
    }

    @Test("Источник звука замолчал совсем — начатая реплика не висит вечно")
    func stalledSourceStillClosesTheTurn() {
        let call = CallFixture()

        call.someoneSpeaks(for: 1.0)
        call.timePassesWithoutAudio(5.0)

        #expect(call.transcript.count == 1)
        #expect(call.transcript.first?.duration.isClose(to: 1.0) == true)
    }

    // MARK: - Каналы

    @Test("Канал реплики определяется источником: речь с микрофона — всегда You")
    func microphoneSpeechAlwaysLandsInYou() {
        let call = CallFixture()

        call.someoneSpeaks(for: 1.2, on: .you)
        call.silenceLasts(1.6, on: .you)

        #expect(call.transcript.first?.channel == .you)
    }

    @Test("Каналы нарезаются независимо: у каждой реплики своя метка")
    func channelsAreSegmentedIndependently() {
        let call = CallFixture()

        call.someoneSpeaks(for: 1.0, on: .them)
        call.silenceLasts(1.6, on: .them)
        call.someoneSpeaks(for: 1.5, on: .you)
        call.silenceLasts(1.6, on: .you)

        #expect(call.transcript.map(\.channel) == [.them, .you])
        #expect(call.transcript.first?.duration.isClose(to: 1.0) == true)
        #expect(call.transcript.last?.duration.isClose(to: 1.5) == true)
    }

    // MARK: - Распознавание за протоколом

    @Test("Закрытая реплика уходит в распознавание, и её текст появляется в транскрипте")
    func closedTurnReachesRecognition() async {
        let call = CallFixture(recognisesAs: "расскажите про ваш опыт")

        call.someoneSpeaks(for: 1.2)
        call.silenceLasts(1.6)
        await call.engine.waitForRecognition()

        let requests = await call.recognizer.requests
        #expect(requests.count == 1, "на распознавание должна была уйти ровно одна реплика")
        #expect(call.transcript.first?.text == "расскажите про ваш опыт")
    }

    @Test("Прослушивание остановили посреди фразы — начатая реплика не потерялась")
    func stoppingListeningClosesTheOpenTurn() throws {
        let call = CallFixture()
        try call.engine.start()

        call.someoneSpeaks(for: 1.3)
        call.engine.stop()

        #expect(call.transcript.count == 1)
        #expect(call.transcript.first?.duration.isClose(to: 1.3) == true)
    }
}

private extension TimeInterval {
    /// Lengths are compared with a tolerance: they are built up frame by frame.
    func isClose(to expected: TimeInterval, tolerance: TimeInterval = 0.01) -> Bool {
        abs(self - expected) < tolerance
    }
}
