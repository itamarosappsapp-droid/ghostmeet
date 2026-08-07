//
//  LeakDedupTranscriptTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Что делает с пойманной протечкой транскрипт: помечает и не показывает модели.
@Suite("Протечка в транскрипте")
struct LeakDedupTranscriptTests {

    private static let question = "Расскажите, чем актор в свифте отличается от обычного класса."
    private static let leak = "Расскажите, чем актор в свифте отличается от обычного класса."

    @Test("Помеченная реплика в промпт не попадает")
    func markedTurnNeverReachesThePrompt() {
        let turns = [
            Turn(channel: .them, text: Self.question, timestamp: 0, duration: 4),
            Turn(channel: .you, text: Self.leak, timestamp: 0.1, duration: 4, isLeak: true),
        ]
        let rendered = TranscriptFormatter.format(turns, limit: TranscriptFormatter.wholeCall)
        #expect(rendered == "Them: \(Self.question)")
        #expect(!rendered.contains("You:"))
    }

    @Test("Помеченная реплика не разрывает склейку Them")
    func markedTurnDoesNotBreakTheRun() {
        // Без пометки строка `You` посреди двух реплик собеседника разрывала бы
        // склейку, и один вопрос читался бы моделью как два.
        let turns = [
            Turn(channel: .them, text: "Расскажите про акторы,", timestamp: 0, duration: 2),
            Turn(channel: .you, text: "Расскажите про акторы,", timestamp: 0.1, duration: 2, isLeak: true),
            Turn(channel: .them, text: "и когда нужен await.", timestamp: 2.5, duration: 2),
        ]
        let rendered = TranscriptFormatter.format(turns, limit: TranscriptFormatter.wholeCall)
        #expect(rendered == "Them: Расскажите про акторы, и когда нужен await.")
    }

    @Test("Непомеченная речь пользователя остаётся на месте")
    func ordinarySpeechStays() {
        let turns = [
            Turn(channel: .them, text: Self.question, timestamp: 0, duration: 4),
            Turn(channel: .you, text: "Актор изолирует своё состояние.", timestamp: 5, duration: 3),
        ]
        let rendered = TranscriptFormatter.format(turns, limit: TranscriptFormatter.wholeCall)
        #expect(rendered == "Them: \(Self.question)\nYou: Актор изолирует своё состояние.")
    }
}

/// Распознавание двух каналов идёт рядом и заканчивается в любом порядке,
/// поэтому решение о протечке обязано переигрываться, а не приниматься однажды.
@MainActor
@Suite("Сессия помечает протечку")
struct LeakDedupSessionTests {

    private static let question = "Расскажите, чем актор в свифте отличается от обычного класса, "
        + "и когда компилятор требует await при обращении к его свойствам."

    /// Ворота, которые тест открывает руками.
    ///
    /// Существуют потому, что вся суть этого слоя — в порядке: распознавание
    /// двух каналов идёт рядом, и тест, полагающийся на то, кто успел первым,
    /// был бы монеткой. Здесь очерёдность задаёт тест.
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// Распознавание, отвечающее по-разному на каждый канал.
    ///
    /// Канал узнаётся по громкости кадров: собеседник звучит в полную силу,
    /// протечка тише — ровно так они и приходят в этом фикстуре.
    private actor ScriptedRecognizer: SpeechRecognizer {
        private let loud: String
        private let quiet: String
        private let holdLoud: Gate?
        let quietDone = Gate()

        init(loud: String, quiet: String, holdLoud: Gate? = nil) {
            self.loud = loud
            self.quiet = quiet
            self.holdLoud = holdLoud
        }

        func transcribe(_ audio: SpeechAudio) async throws -> String {
            let isLoud = (audio.samples.first.map(abs) ?? 0) > 0.2
            if isLoud {
                await holdLoud?.wait()
                return loud
            }
            await quietDone.open()
            return quiet
        }
    }

    /// Звонок, в котором говорят оба канала сразу.
    @MainActor
    private struct Call {
        let engine: SessionEngine
        let clock: ManualClock
        let recognizer: ScriptedRecognizer
        private let frameLength: TimeInterval = 0.1

        init(them: String, you: String, holdThem: Gate? = nil) {
            let clock = ManualClock()
            let recognizer = ScriptedRecognizer(loud: them, quiet: you, holdLoud: holdThem)
            self.clock = clock
            self.recognizer = recognizer
            self.engine = SessionEngine(recognizer: recognizer, clock: clock)
            // Строгий режим здесь только мешал бы: он и так не пускает протечку,
            // а этот слой существует ровно для того, что он пропускает.
            engine.isLeakyRoute = { false }
        }

        func bothSpeak(for seconds: TimeInterval) {
            feed(seconds: seconds) {
                [
                    AudioFrames.speech(channel: .them, duration: frameLength),
                    AudioFrames.speech(channel: .you, duration: frameLength, loudness: 0.08),
                ]
            }
        }

        func quiet(for seconds: TimeInterval) {
            feed(seconds: seconds) {
                [
                    AudioFrames.silence(channel: .them, duration: frameLength),
                    AudioFrames.silence(channel: .you, duration: frameLength),
                ]
            }
        }

        private func feed(seconds: TimeInterval, frames make: () -> [AudioFrame]) {
            for _ in 0..<Int((seconds / frameLength).rounded()) {
                clock.advance(by: frameLength)
                for frame in make() { engine.ingest(frame) }
            }
        }
    }

    @Test("Реплика You, повторяющая соседнюю Them, помечается протечкой")
    func leakIsMarked() async {
        let call = Call(them: Self.question, you: Self.question)
        call.bothSpeak(for: 3)
        call.quiet(for: 2)
        await call.engine.waitForRecognition()

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.count == 1)
        #expect(you.first?.isLeak == true)
        #expect(!TranscriptFormatter.format(call.engine.transcript, limit: 0).contains("You:"))
    }

    @Test("Метка ставится и тогда, когда слова Them доехали позже")
    func lateThemWordsStillConvict() async {
        // Обвинитель приходит после обвиняемого: распознавание `You` вернулось
        // первым, и в тот момент помечать реплику было нечем. Решение обязано
        // переиграться, когда доедут слова собеседника.
        let holdThem = Gate()
        let call = Call(them: Self.question, you: Self.question, holdThem: holdThem)
        call.bothSpeak(for: 3)
        call.quiet(for: 2)

        await call.recognizer.quietDone.wait()
        await holdThem.open()
        await call.engine.waitForRecognition()

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.first?.isLeak == true)
    }

    @Test("Обычный ответ пользователя протечкой не помечается")
    func ordinaryAnswerIsNotMarked() async {
        let call = Call(
            them: Self.question,
            you: "Актор изолирует своё состояние, поэтому обращение извне асинхронно."
        )
        call.bothSpeak(for: 3)
        call.quiet(for: 2)
        await call.engine.waitForRecognition()

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.first?.isLeak == false)
        #expect(TranscriptFormatter.format(call.engine.transcript, limit: 0).contains("You:"))
    }
}
