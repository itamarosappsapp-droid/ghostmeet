//
//  SessionControllerTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// The microphone gate, scripted by the test instead of asked of the system.
///
/// Counts how many times it was asked, because "ask again on the next press" is
/// the behaviour that lets a user fix a refusal in System Settings without
/// restarting the app — and it is invisible unless counted.
private final class MicrophoneGate: @unchecked Sendable {
    private(set) var timesAsked = 0
    var answer: Bool

    init(answer: Bool) {
        self.answer = answer
    }

    func respond() async -> Bool {
        timesAsked += 1
        return answer
    }
}

/// A source that starts and then stays silent. Enough to reach `isListening`
/// without any audio hardware.
private final class SilentSource: AudioSource, @unchecked Sendable {
    let channel: Channel
    private(set) var isRunning = false

    init(channel: Channel = .you) {
        self.channel = channel
    }

    func start(onFrame: @escaping AudioFrameHandler) throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

/// A source that cannot start — no input format, device gone, device busy.
private final class RefusingSource: AudioSource, @unchecked Sendable {
    static let reason = "Микрофон занят другим приложением"

    let channel: Channel = .you
    private(set) var isRunning = false

    func start(onFrame: @escaping AudioFrameHandler) throws {
        throw NSError(
            domain: "GhostMeetTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: Self.reason]
        )
    }

    func stop() {}
}

// MARK: - Helpers

/// Runs `body` against a throwaway defaults suite, so no test touches the user's
/// own settings.
@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore) throws -> T) rethrows -> T {
    let name = "GhostMeetSessionControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()))
}

/// Waits for something that happens on a later turn of the main actor.
///
/// `followThresholds` re-reads the store from inside a `Task`, so the change is
/// visible one hop later, not synchronously. Polling beats sleeping: the test
/// finishes as soon as the value arrives.
@MainActor
private func eventually(
    _ condition: () -> Bool,
    attempts: Int = 200
) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

// MARK: - Scenarios

@MainActor
@Suite("Запуск и остановка прослушивания")
struct SessionControllerStartTests {

    @Test("Пользователь запретил доступ к микрофону — прослушивание не началось")
    func deniedMicrophoneKeepsTheSessionStopped() async {
        let gate = MicrophoneGate(answer: false)
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { await gate.respond() }
        )

        controller.start()
        await controller.waitForStart()

        #expect(controller.isListening == false)
        #expect(controller.failure == .microphoneDenied)
        #expect(controller.isStarting == false)
        // Отказ ведёт в «Системные настройки», поэтому UI должен уметь показать
        // кнопку именно для этого случая.
        #expect(controller.failure?.isPermissionDenied == true)
    }

    @Test("После отказа доступ спрашивается заново, и с разрешением сессия стартует")
    func aRefusalIsNotRememberedBetweenAttempts() async {
        let gate = MicrophoneGate(answer: false)
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { await gate.respond() }
        )

        controller.start()
        await controller.waitForStart()
        #expect(gate.timesAsked == 1)
        #expect(controller.failure == .microphoneDenied)

        // Пользователь ушёл в «Системные настройки», выдал доступ и вернулся.
        gate.answer = true
        controller.start()
        await controller.waitForStart()

        #expect(gate.timesAsked == 2, "повторное нажатие обязано спросить доступ заново")
        #expect(controller.isListening)
        #expect(controller.failure == nil, "прошлый отказ не должен оставаться на экране")

        controller.stop()
    }

    @Test("Захват не смог стартовать — причина показана словами источника")
    func aCaptureFailureSurfacesItsOwnReason() async {
        let controller = SessionController(
            engine: SessionEngine(sources: [RefusingSource()]),
            requestMicrophoneAccess: { true }
        )

        controller.start()
        await controller.waitForStart()

        #expect(controller.isListening == false)
        #expect(controller.failure == .captureFailed(RefusingSource.reason))
        // Это не отказ в разрешении: вести пользователя в «Системные настройки»
        // здесь бессмысленно.
        #expect(controller.failure?.isPermissionDenied == false)
        #expect(controller.failure?.message == RefusingSource.reason)
    }

    @Test("Доступ выдан — сессия слушает и останавливается по команде")
    func aGrantedMicrophoneStartsAndStopsListening() async {
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true }
        )

        controller.start()
        await controller.waitForStart()
        #expect(controller.isListening)
        #expect(controller.failure == nil)

        controller.stop()
        #expect(controller.isListening == false)
    }
}

@MainActor
@Suite("Пороги нарезки доезжают до движка")
struct SessionControllerThresholdTests {

    @Test("Пороги из настроек применяются к движку сразу при подписке")
    func thresholdsAreAppliedOnSubscription() {
        withScratchSettings { settings in
            settings.turnSegmentation.pauseThreshold = 1.4
            let controller = SessionController(engine: SessionEngine())

            controller.followThresholds(of: settings)

            #expect(controller.engine.config.pauseThreshold == 1.4)
        }
    }

    @Test("Пользователь подвинул порог во время звонка — движок это увидел без перезапуска")
    func aThresholdChangedMidCallReachesTheEngine() async {
        let settings = withScratchSettings { $0 }
        let controller = SessionController(engine: SessionEngine())
        controller.followThresholds(of: settings)

        settings.turnSegmentation.pauseThreshold = 1.7

        let arrived = await eventually { controller.engine.config.pauseThreshold == 1.7 }
        #expect(arrived, "изменение порога не доехало до движка — подписка развалилась после первого срабатывания")
    }

    @Test("Пороги меняли несколько раз подряд — движок следует за каждым изменением")
    func theEngineKeepsFollowingAfterTheFirstChange() async {
        let settings = withScratchSettings { $0 }
        let controller = SessionController(engine: SessionEngine())
        controller.followThresholds(of: settings)

        // Подписка пересоздаётся на каждом изменении, поэтому регрессия здесь
        // выглядит так: первое изменение проходит, второе молча теряется.
        for threshold in [1.1, 1.3, 1.9] as [TimeInterval] {
            settings.turnSegmentation.pauseThreshold = threshold
            let arrived = await eventually { controller.engine.config.pauseThreshold == threshold }
            #expect(arrived, "движок перестал следовать за настройками на пороге \(threshold)")
        }
    }

    @Test("Изменился другой порог — движок берёт и его")
    func everyThresholdIsFollowedNotJustThePause() async {
        let settings = withScratchSettings { $0 }
        let controller = SessionController(engine: SessionEngine())
        controller.followThresholds(of: settings)

        settings.turnSegmentation.safetyFlushInterval = 22

        let arrived = await eventually { controller.engine.config.safetyFlushInterval == 22 }
        #expect(arrived)
    }
}
