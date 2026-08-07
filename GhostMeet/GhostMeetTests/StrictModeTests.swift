import Foundation
import Testing
@testable import GhostMeet

/// Строгий режим: пока собеседник звучит, микрофон не открывает реплику `You`.
///
/// Самый дешёвый из трёх слоёв ADR-0009 и единственный, который ничего не стоит
/// в наушниках. Без защиты замер беспощаден: из 19 секунд звучащего вопроса 17.8
/// попадают в канал `You` как речь пользователя.
@MainActor
@Suite("Строгий режим канала You")
struct StrictModeTests {

    /// Звонок, в котором оба канала звучат вперемешку.
    ///
    /// `CallFixture` кормит по одному каналу за раз, а вся суть строгого режима
    /// — в том, что происходит, когда `Them` и `You` звучат одновременно.
    @MainActor
    private struct Call {
        let engine: SessionEngine
        let clock: ManualClock
        private let frameLength: TimeInterval = 0.1

        init(leakyRoute: Bool = true) {
            let clock = ManualClock()
            self.clock = clock
            self.engine = SessionEngine(recognizer: RecognizerSpy(reply: ""), clock: clock)
            engine.isLeakyRoute = { leakyRoute }
        }

        /// Собеседник говорит; из динамиков это же попадает в микрофон.
        func themSpeaksAndLeaks(for seconds: TimeInterval) {
            feed(seconds: seconds) {
                [
                    AudioFrames.speech(channel: .them, duration: frameLength),
                    // Протечка тише оригинала, но гейт проходит с запасом —
                    // ровно так она и выглядит на записях.
                    AudioFrames.speech(channel: .you, duration: frameLength, loudness: 0.08),
                ]
            }
        }

        /// Собеседник говорит, а микрофон при этом чист — наушники.
        func themSpeaksAlone(for seconds: TimeInterval) {
            feed(seconds: seconds) { [AudioFrames.speech(channel: .them, duration: frameLength)] }
        }

        /// Говорит пользователь, и больше никто.
        func userSpeaks(for seconds: TimeInterval) {
            feed(seconds: seconds) { [AudioFrames.speech(channel: .you, duration: frameLength)] }
        }

        /// Тишина в обоих каналах.
        func quiet(for seconds: TimeInterval) {
            feed(seconds: seconds) {
                [
                    AudioFrames.silence(channel: .them, duration: frameLength),
                    AudioFrames.silence(channel: .you, duration: frameLength),
                ]
            }
        }

        /// Тишина, которую не сопровождают кадры: паузу закрывает сторожевой тик.
        func timePasses(_ seconds: TimeInterval) {
            clock.advance(by: seconds)
            engine.tick()
        }

        private func feed(seconds: TimeInterval, frames: () -> [AudioFrame]) {
            let count = Int((seconds / frameLength).rounded())
            for _ in 0..<count {
                clock.advance(by: frameLength)
                for frame in frames() { engine.ingest(frame) }
            }
        }
    }

    @Test("Эхо во время речи Them реплики You не создаёт")
    func theLeakNeverBecomesATurn() {
        let call = Call()

        call.themSpeaksAndLeaks(for: 3)
        call.timePasses(2)

        let channels = call.engine.transcript.map(\.channel)
        #expect(channels == [.them], "в транскрипте обязан быть один вопрос собеседника и ничего больше")
    }

    @Test("Речь пользователя до начала Them доживает до транскрипта целиком")
    func aTurnStartedFirstIsNeverCutOff() {
        let call = Call()

        // Пользователь заговорил первым — например, договаривает предыдущий
        // ответ, — и собеседник вступил поверх.
        call.userSpeaks(for: 1)
        call.themSpeaksAndLeaks(for: 2)
        call.timePasses(2)

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.count == 1, "открытую реплику пользователя обрывать нельзя")
        #expect(
            (you.first?.duration ?? 0) >= 2.5,
            "реплика оборвалась на середине: \(you.first?.duration ?? 0) с"
        )
    }

    @Test("В наушниках строгий режим не включается")
    func headphonesTurnTheModeOff() {
        // Тот же сценарий, что и в первом тесте, но маршрут безопасный: микрофон
        // слышит только пользователя, и перебивание обязано доехать.
        let call = Call(leakyRoute: false)

        call.themSpeaksAlone(for: 1)
        call.themSpeaksAndLeaks(for: 2)
        call.timePasses(2)

        let channels = Set(call.engine.transcript.map(\.channel))
        #expect(channels == [.them, .you], "в наушниках речь поверх собеседника — это речь, а не эхо")
    }

    @Test("Хвост после конца речи Them учтён: затухание реплики не открывает")
    func theTailOfTheLeakIsHeldShut() {
        let call = Call()

        call.themSpeaksAlone(for: 2)
        // Динамик замолк, а комната ещё звенит: 0.3 с — внутри измеренного
        // хвоста (максимум 170 мс акустики плюс кадр в 85 мс).
        call.userSpeaks(for: 0.3)
        call.timePasses(2)

        #expect(
            call.engine.transcript.allSatisfy { $0.channel == .them },
            "затухание в микрофоне не должно становиться репликой пользователя"
        )
    }

    @Test("После хвоста пользователь снова слышен")
    func speechAfterTheTailOpensATurn() {
        let call = Call()

        call.themSpeaksAlone(for: 2)
        // Пауза длиннее хвоста — дальше микрофон принадлежит пользователю.
        call.quiet(for: SessionEngine.echoTail + 0.2)
        call.userSpeaks(for: 1)
        call.timePasses(2)

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.count == 1, "ответ после вопроса обязан попасть в транскрипт")
    }

    @Test("Тихий Them микрофон не запирает: решение берётся из того же гейта")
    func aThemQuieterThanTheGateHoldsNothingShut() {
        // «Звучит» определяется гейтом, которым нарезается `Them`, а не вторым
        // порогом. Значит канал, который не проходит гейт, ничего и не запирает:
        // он и реплику-то не открывает.
        let call = Call()

        call.themSpeaksAndLeaks(for: 0)   // ничего не звучало вообще
        call.userSpeaks(for: 1)
        call.timePasses(2)

        let you = call.engine.transcript.filter { $0.channel == .you }
        #expect(you.count == 1, "молчащий Them не имеет права запирать микрофон")
    }

    @Test("Хвост держит границу там, где её поставил замер")
    func theTailIsTheMeasuredNumber() {
        // Число подбиралось замером по записям протечки, а не на глаз: 170 мс
        // акустики (максимум на 34 концах фраз), 85 мс на длину кадра и столько
        // же на разницу путей захвата. Уменьшать его без нового замера обоих
        // путей нельзя — цена ошибки в меньшую сторону это целая реплика
        // собеседника, записанная как речь пользователя.
        #expect(SessionEngine.echoTail == 0.4)
        #expect(
            SessionEngine.echoTail < TurnSegmentationConfig.default.pauseThreshold,
            "хвост длиннее паузы означал бы, что реплика Them закрывается позже, чем снимается запрет"
        )
    }
}
