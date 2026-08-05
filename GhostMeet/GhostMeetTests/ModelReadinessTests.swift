//
//  ModelReadinessTests.swift
//  GhostMeetTests
//

import Foundation
import Observation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A source that starts and then stays silent — enough to reach `isListening`
/// without any audio hardware.
private final class SilentSource: AudioSource, @unchecked Sendable {
    let channel: Channel = .you
    private(set) var isRunning = false

    func start(onFrame: @escaping AudioFrameHandler) throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

/// The microphone gate, scripted by the test.
///
/// Counts the asks, because "the model is not ready" has to stop the start
/// *before* the system dialog: a permission prompt raised for a session that
/// cannot transcribe anything is pure noise, and the count is the only way to
/// see that it did not happen.
private final class MicrophoneGate: @unchecked Sendable {
    private(set) var timesAsked = 0
    var answer = true

    func respond() async -> Bool {
        timesAsked += 1
        return answer
    }
}

// MARK: - Helpers

/// Runs `body` against a throwaway defaults suite, so no test touches the user's
/// own settings.
@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore) throws -> T) rethrows -> T {
    let name = "GhostMeetModelReadinessTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()))
}

/// Waits for something that happens on a later turn of the main actor.
///
/// Both the phase mirror in `SpeechModelStatus` and the observation used by
/// `startWhenRecognitionIsReady()` land one hop later, not synchronously.
@MainActor
private func eventually(_ condition: () -> Bool, attempts: Int = 2_000) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 200_000)
    }
    return condition()
}

// MARK: - The gate on listening

@MainActor
@Suite("Прослушивание ждёт готовности модели")
struct ListeningWaitsForTheModelTests {

    @Test("Модель ещё не готова — прослушивание не стартует и микрофон даже не спрашивают")
    func anUnreadyModelStopsTheStart() async {
        let gate = MicrophoneGate()
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { await gate.respond() },
            isRecognitionReady: { false }
        )

        controller.start()
        await controller.waitForStart()

        #expect(controller.isListening == false)
        #expect(gate.timesAsked == 0, "разрешение на микрофон нельзя спрашивать ради сессии, которая не сможет распознать ни слова")
        #expect(controller.canStartListening == false, "окно обязано знать, что кнопку нажимать нельзя")
        // Неготовая модель — не отказ и не поломка: это состояние проходит само,
        // а осевший в окне баннер об ошибке — нет.
        #expect(controller.failure == nil)
    }

    @Test("Модель готова — прослушивание стартует")
    func aReadyModelLetsTheSessionStart() async {
        let gate = MicrophoneGate()
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { await gate.respond() },
            isRecognitionReady: { true }
        )

        #expect(controller.canStartListening)

        controller.start()
        await controller.waitForStart()

        #expect(controller.isListening)
        #expect(gate.timesAsked == 1)
        #expect(controller.failure == nil)

        controller.stop()
    }

    @Test("Готовность появилась после отказа — следующее нажатие уже работает")
    func theGateOpensWhenTheModelArrives() async {
        let readiness = Readiness()
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true },
            isRecognitionReady: { readiness.isReady }
        )

        controller.start()
        await controller.waitForStart()
        #expect(controller.isListening == false)

        readiness.isReady = true
        controller.start()
        await controller.waitForStart()

        #expect(controller.isListening, "как только модель готова, кнопка обязана оживать без перезапуска")

        controller.stop()
    }

    /// A readiness flag the test flips by hand.
    private final class Readiness: @unchecked Sendable {
        var isReady = false
    }
}

@MainActor
@Suite("Автостарт дожидается модели")
struct StartWhenReadyTests {

    @Test("Модель ещё качается — сессия ждёт; догрузилась — стартует сама")
    func theSessionStartsTheMomentTheModelIsReady() async {
        let door = Gate()
        let status = withScratchSettings { settings in
            SpeechModelStatus(
                store: settings,
                provider: FakeSpeechModelProvider(download: .held(door))
            )
        }
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true },
            isRecognitionReady: { status.phase.isReady }
        )

        status.prepare()
        let downloading = await eventually { status.phase.isBusy }
        #expect(downloading, "подготовка модели должна была начаться")

        controller.startWhenRecognitionIsReady()
        #expect(controller.isListening == false, "нельзя слушать, пока модель качается")

        await door.open()

        let started = await eventually { controller.isListening }
        #expect(started, "как только модель готова, отложенный старт обязан сработать")
        #expect(status.phase.isReady)

        controller.stop()
    }

    @Test("Модель уже готова — отложенный старт срабатывает сразу")
    func aReadyModelStartsWithoutWaiting() async {
        let status = withScratchSettings { settings in
            SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider())
        }
        let controller = SessionController(
            engine: SessionEngine(sources: [SilentSource()]),
            requestMicrophoneAccess: { true },
            isRecognitionReady: { status.phase.isReady }
        )

        status.prepare()
        let ready = await eventually { status.phase.isReady }
        #expect(ready)

        controller.startWhenRecognitionIsReady()
        await controller.waitForStart()

        #expect(controller.isListening)

        controller.stop()
    }
}

// MARK: - What the window says

@Suite("Причина недоступности написана словами")
struct ReadinessWordingTests {

    @Test("Причина есть ровно тогда, когда слушать нельзя")
    func theReasonIsPresentExactlyWhenListeningIsBlocked() {
        let blocked: [SpeechModelPhase] = [
            .idle,
            .downloading(fraction: 0.42),
            .loading,
            .failed("нет сети")
        ]
        for phase in blocked {
            #expect(phase.isReady == false)
            #expect(phase.listeningBlockedReason != nil, "фаза \(phase) обязана объяснить, почему кнопка не нажимается")
        }

        #expect(SpeechModelPhase.ready.isReady)
        #expect(SpeechModelPhase.ready.listeningBlockedReason == nil)
    }

    @Test("Это человеческий текст, а не код фазы")
    func theReasonIsWrittenForAHuman() {
        for phase in [SpeechModelPhase.idle, .downloading(fraction: 0.42), .loading, .failed("нет сети")] {
            let reason = phase.listeningBlockedReason ?? ""
            #expect(reason.count > 20, "«\(reason)» — это не объяснение")
            #expect(!reason.contains("SpeechModelPhase"))
            #expect(!reason.contains("fraction"))
        }
    }

    @Test("Прогресс скачивания виден в процентах")
    func theDownloadReasonCarriesTheProgress() {
        let reason = SpeechModelPhase.downloading(fraction: 0.42).listeningBlockedReason ?? ""
        #expect(reason.contains("42"))
        // Округление, а не обрезание: 99.6% не должны выглядеть как 99%.
        #expect(SpeechModelPhase.downloading(fraction: 0.996).summary.contains("100"))
    }

    @Test("Причина отказа модели доезжает до текста в окне")
    func aFailureCarriesItsOwnReason() {
        let reason = SpeechModelPhase.failed("нет сети").listeningBlockedReason ?? ""
        #expect(reason.contains("нет сети"))
    }
}
