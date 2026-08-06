//
//  TranscriptWindowTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// How the stored conversation becomes the block the model reads.
///
/// Two behaviours live here and nowhere else, and both exist because people
/// speak with pauses (ADR-0008). A question cut in half by the pause threshold
/// comes back together as one line, and the window covers the whole call with a
/// ceiling counted in characters instead of turns.
///
/// The storage is deliberately not part of any of it: every test below checks
/// that `SessionEngine`'s record — one turn per closed stretch of speech, with
/// its own timestamp — comes out the other side unchanged.
@Suite("Транскрипт в промпте")
struct TranscriptWindowTests {

    // MARK: - Склейка

    @Test("Вопрос, разрезанный паузой, приходит в промпт одной строкой")
    func aQuestionSplitByAPauseArrivesAsOneLine() {
        let broken = [
            Turn(channel: .them, text: "а как вы", timestamp: 0, duration: 1.2),
            Turn(channel: .them, text: "устроили кэш в этом проекте?", timestamp: 3, duration: 1.5),
        ]

        #expect(
            TranscriptFormatter.format(broken, limit: TranscriptFormatter.wholeCall)
                == "Them: а как вы устроили кэш в этом проекте?"
        )
    }

    @Test("Склейка живёт в слое промптов: реплики в транскрипте остаются как были")
    func mergingLeavesTheStoredTurnsAlone() {
        let stored = [
            Turn(channel: .them, text: "а как вы", timestamp: 0, duration: 1.2),
            Turn(channel: .them, text: "устроили кэш?", timestamp: 3, duration: 1.5),
        ]

        _ = TranscriptFormatter.format(stored, limit: TranscriptFormatter.wholeCall)

        #expect(stored.count == 2, "хранилище транскрипта склейка не трогает")
        #expect(stored.map(\.timestamp) == [0, 3])
        #expect(stored.map(\.text) == ["а как вы", "устроили кэш?"])
    }

    @Test("Реплика другого канала посередине разрывает склейку")
    func aTurnOfTheOtherChannelBreaksTheRun() {
        let call = [
            Turn(channel: .them, text: "расскажите про индексы", timestamp: 0, duration: 1),
            Turn(channel: .you, text: "их несколько видов", timestamp: 1.4, duration: 1),
            Turn(channel: .them, text: "а какой быстрее?", timestamp: 2.8, duration: 1),
        ]

        #expect(TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall) == """
        Them: расскажите про индексы
        You: их несколько видов
        Them: а какой быстрее?
        """)
    }

    @Test("Чужая реплика без распознанного текста тоже разрывает склейку")
    func anUnrecognisedTurnOfTheOtherChannelStillBreaksTheRun() {
        let call = [
            Turn(channel: .them, text: "расскажите про индексы", timestamp: 0, duration: 1),
            Turn(channel: .you, text: "", timestamp: 1.2, duration: 1),
            Turn(channel: .them, text: "а какой быстрее?", timestamp: 2.4, duration: 1),
        ]

        #expect(TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall) == """
        Them: расскажите про индексы
        Them: а какой быстрее?
        """, "слов у неё нет, но говорил-то пользователь — это два разных вопроса")
    }

    @Test("Разрыв больше порога склейки — это два разных вопроса, а не один")
    func aLongSilenceKeepsTwoQuestionsApart() {
        let call = [
            Turn(channel: .them, text: "первый вопрос", timestamp: 0, duration: 1),
            Turn(
                channel: .them,
                text: "второй вопрос",
                timestamp: 1 + TranscriptFormatter.mergeGap + 0.1,
                duration: 1
            ),
        ]

        #expect(TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall) == """
        Them: первый вопрос
        Them: второй вопрос
        """)
    }

    @Test("Своя реплика без слов внутри вопроса склейку не рвёт и пустоты не добавляет")
    func anUnrecognisedTurnOfTheSameChannelIsSkipped() {
        let call = [
            Turn(channel: .them, text: "а как вы", timestamp: 0, duration: 1),
            Turn(channel: .them, text: "", timestamp: 1.5, duration: 0.6),
            Turn(channel: .them, text: "это масштабировали?", timestamp: 2.6, duration: 1),
        ]

        #expect(
            TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall)
                == "Them: а как вы это масштабировали?"
        )
    }

    @Test("Порог склейки строго выше любого порога паузы, который может выставить пользователь")
    func theMergeGapOutrunsEveryPauseThresholdAUserCanSet() {
        #expect(
            TranscriptFormatter.mergeGap > TurnSegmentationConfig.pauseThresholdRange.upperBound,
            "иначе на верхнем краю ползунка склейка тихо перестала бы работать"
        )
        #expect(TranscriptFormatter.mergeGap > TurnSegmentationConfig.default.pauseThreshold)
        #expect(
            TranscriptFormatter.mergeGap < TurnSegmentationConfig.default.safetyFlushInterval,
            "монолог, разрезанный страховочным таймером, обязан склеиваться обратно"
        )
    }

    // MARK: - Окно на весь звонок

    @Test("Длинный разговор доходит до промпта целиком, от первой реплики до последней")
    func thewholeCallReachesThePrompt() {
        let call = (0..<300).map { index in
            Turn(
                channel: index.isMultiple(of: 2) ? .them : .you,
                text: "реплика-\(String(format: "%03d", index))",
                timestamp: Double(index) * 10,
                duration: 2
            )
        }

        let window = TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall)

        #expect(window.contains("реплика-000"), "начало звонка модель тоже видит")
        #expect(window.contains("реплика-299"))
        #expect(lines(of: window).count == 300)
        #expect(!window.contains(TranscriptFormatter.truncationNotice))
    }

    @Test("Интервью на 45 минут влезает под потолок целиком")
    func aFortyFiveMinuteInterviewFitsWhole() {
        // ≈ 27 000 символов: столько наговаривают за 45 минут вдвоём.
        let call = (0..<200).map { index in
            Turn(
                channel: index.isMultiple(of: 2) ? .them : .you,
                text: String(repeating: "слово ", count: 22) + "\(index)",
                timestamp: Double(index) * 13,
                duration: 6
            )
        }

        let window = TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall)

        #expect(window.count < TranscriptFormatter.characterBudget)
        #expect(!window.contains(TranscriptFormatter.truncationNotice), "сжимать тут нечего")
        #expect(lines(of: window).count == 200)
    }

    // MARK: - Потолок

    @Test("Разговор перерос потолок — старое отваливается спереди, новое остаётся")
    func theOldestLinesFallOffFirst() {
        let long = (0..<400).map { index in
            Turn(
                channel: .them,
                text: "\(index)-" + String(repeating: "я", count: 300),
                timestamp: Double(index) * 10,
                duration: 2
            )
        }

        let window = TranscriptFormatter.format(long, limit: TranscriptFormatter.wholeCall)

        #expect(window.contains("399-"), "последняя реплика обязана остаться")
        #expect(!window.contains("Them: 0-"), "самая старая — первый кандидат на вылет")
        #expect(window.hasPrefix(TranscriptFormatter.truncationNotice), "модели сказано, что начало опущено")
        #expect(window.count < TranscriptFormatter.characterBudget + 200)
    }

    @Test("Одна огромная реплика всё равно уходит: пустой разговор был бы хуже")
    func theNewestLineIsNeverDropped() {
        let monolith = [
            Turn(channel: .them, text: String(repeating: "a", count: 200), timestamp: 0, duration: 1),
        ]

        #expect(
            TranscriptFormatter.format(monolith, limit: TranscriptFormatter.wholeCall, budget: 10)
                == "Them: " + String(repeating: "a", count: 200)
        )
    }

    @Test("Потолок снят — обрезка не делается вовсе")
    func aBudgetOfZeroMeansNoCeiling() {
        let call = [Turn(channel: .them, text: "вопрос", timestamp: 0, duration: 1)]

        #expect(
            TranscriptFormatter.format(call, limit: TranscriptFormatter.wholeCall, budget: 0)
                == "Them: вопрос"
        )
    }

    // MARK: - Явное окно

    @Test("Окно задано числом — считаются строки после склейки, а не исходные реплики")
    func anExplicitLimitCountsMergedLines() {
        let call = [
            Turn(channel: .them, text: "первый", timestamp: 0, duration: 1),
            Turn(channel: .them, text: "вопрос", timestamp: 2, duration: 1),
            Turn(channel: .you, text: "ответ", timestamp: 6, duration: 1),
            Turn(channel: .them, text: "второй вопрос", timestamp: 12, duration: 1),
        ]

        #expect(TranscriptFormatter.format(call, limit: 2) == """
        You: ответ
        Them: второй вопрос
        """)
    }

    @Test("Реплик пока нет вовсе — пустая строка, а не заголовок ни о чём")
    func anEmptyTranscriptRendersAsNothing() {
        #expect(TranscriptFormatter.format([], limit: TranscriptFormatter.wholeCall).isEmpty)
        #expect(
            TranscriptFormatter.format(
                [Turn(channel: .them, text: "   ", timestamp: 0, duration: 1)],
                limit: TranscriptFormatter.wholeCall
            ).isEmpty
        )
    }

    // MARK: - Хелперы

    private func lines(of window: String) -> [String] {
        window
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You: ") }
    }
}
