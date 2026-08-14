//
//  CaptureVisibilityTests.swift
//  GhostMeetTests
//

import AppKit
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Support

/// Runs `body` against a throwaway defaults suite: no test touches the user's
/// own window geometry or settings.
@MainActor
private func withScratchSettings<T>(_ body: (SettingsStore, UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetCaptureVisibilityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(SettingsStore(defaults: defaults, secrets: InMemorySecretStore()), defaults)
}

/// A registry that registers nothing: these scenarios are about a window, and a
/// real global chord would be taken from the machine running the suite.
@MainActor
private final class FakeHotkeyRegistry: HotkeyRegistry {

    var onPress: ((HotkeyAction) -> Void)?

    @discardableResult
    func replaceAll(with bindings: [HotkeyAction: Hotkey]) -> Set<HotkeyAction> { [] }
}

/// A source that starts and stays silent — enough to reach `isListening` without
/// any audio hardware.
private final class SilentSource: AudioSource, @unchecked Sendable {
    let channel: Channel = .you
    private(set) var isRunning = false

    func start(onFrame: @escaping AudioFrameHandler) throws { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
private func makeOverlay(session: SessionController) -> OverlayWindowController {
    withScratchSettings { settings, defaults in
        OverlayWindowController(
            session: session,
            recognition: SpeechModelStatus(store: settings, provider: FakeSpeechModelProvider()),
            hotkeys: HotkeyCenter(store: settings, registry: FakeHotkeyRegistry()),
            openSettings: { _ in },
            stateStore: WindowStateStore(defaults: defaults)
        )
    }
}

@MainActor
private func makeStoppedSession() -> SessionController {
    SessionController(engine: SessionEngine(sources: [SilentSource()]), requestMicrophoneAccess: { true })
}

// MARK: - Умолчание

@MainActor
@Suite("Невидимость включена, пока её не выключили руками")
struct CaptureVisibilityDefaultTests {

    @Test("На старте окно скрыто от захвата — это обещание продукта, а не настройка")
    func startsHidden() {
        let overlay = makeOverlay(session: makeStoppedSession())
        overlay.show()
        defer { overlay.hide() }

        #expect(overlay.isHiddenFromCapture)
        #expect(overlay.windowSharingType == NSWindow.SharingType.none,
                "обещание должно доехать до самого окна, а не остаться в поле")
    }

    @Test("Состояние не переживает перезапуск: новый экземпляр снова скрыт")
    func doesNotSurviveARelaunch() {
        let session = makeStoppedSession()

        let first = makeOverlay(session: session)
        first.show()
        first.setHiddenFromCapture(false)
        #expect(first.isHiddenFromCapture == false)
        first.hide()

        // Второй контроллер — это следующий запуск приложения. Переключатель,
        // оставленный включённым вчера ради записи ролика, не имеет права
        // всплыть сегодня на собеседовании.
        let second = makeOverlay(session: session)
        second.show()
        defer { second.hide() }

        #expect(second.isHiddenFromCapture, "видимость обязана сбрасываться при каждом запуске")
        #expect(second.windowSharingType == NSWindow.SharingType.none)
    }
}

// MARK: - Переключение

@MainActor
@Suite("Переключатель доходит до окна в обе стороны")
struct CaptureVisibilitySwitchTests {

    @Test("Выключение невидимости делает окно видимым для захвата")
    func turningItOffMakesTheWindowCapturable() {
        let overlay = makeOverlay(session: makeStoppedSession())
        overlay.show()
        defer { overlay.hide() }

        overlay.setHiddenFromCapture(false)

        #expect(overlay.isHiddenFromCapture == false)
        #expect(overlay.windowSharingType == .readOnly,
                "обычное окно macOS — .readOnly: захват читает, рисовать в него никто не может")
    }

    @Test("Возврат невидимости снова убирает окно из захвата")
    func turningItBackOnHidesTheWindowAgain() {
        let overlay = makeOverlay(session: makeStoppedSession())
        overlay.show()
        defer { overlay.hide() }

        overlay.setHiddenFromCapture(false)
        overlay.setHiddenFromCapture(true)

        #expect(overlay.isHiddenFromCapture)
        #expect(overlay.windowSharingType == NSWindow.SharingType.none)
    }

    @Test("Окно настроек следует за тем же переключателем")
    func otherWindowsFollow() {
        let overlay = makeOverlay(session: makeStoppedSession())
        overlay.show()
        defer { overlay.hide() }

        var announced: [NSWindow.SharingType] = []
        overlay.onCaptureVisibilityChange = { announced.append($0) }

        overlay.setHiddenFromCapture(false)
        overlay.setHiddenFromCapture(true)

        #expect(announced == [.readOnly, NSWindow.SharingType.none],
                "иначе «приложение невидимо» превращается в «невидимо одно окно»")
    }

    @Test("Повторное присвоение того же состояния никого не будит")
    func settingTheSameValueChangesNothing() {
        let overlay = makeOverlay(session: makeStoppedSession())
        overlay.show()
        defer { overlay.hide() }

        var announced = 0
        overlay.onCaptureVisibilityChange = { _ in announced += 1 }

        overlay.setHiddenFromCapture(true)

        #expect(announced == 0)
    }
}

// MARK: - Боевой режим

@MainActor
@Suite("Прослушивание замораживает выбор, а не отменяет его")
struct CaptureVisibilityDuringSessionTests {

    @Test("Старт прослушивания сохраняет видимость, если её выбрали до звонка")
    func startingASessionKeepsTheChosenState() async {
        let session = makeStoppedSession()
        let overlay = makeOverlay(session: session)
        overlay.show()
        defer { overlay.hide() }

        overlay.setHiddenFromCapture(false)

        session.start()
        await session.waitForStart()
        #expect(session.isListening)

        // Нажатая кнопка «Слушать» блокирует переключатель, а не саму видимость:
        // человек выбрал это состояние осознанно, и подменять его на старте
        // значило бы отменять его выбор молча.
        #expect(overlay.isHiddenFromCapture == false, "старт звонка не имеет права сам менять видимость")
        #expect(overlay.windowSharingType == .readOnly)

        session.stop()
    }

    @Test("Старт прослушивания не трогает и невидимость, выбранную по умолчанию")
    func startingASessionKeepsTheDefaultToo() async {
        let session = makeStoppedSession()
        let overlay = makeOverlay(session: session)
        overlay.show()
        defer { overlay.hide() }

        session.start()
        await session.waitForStart()

        #expect(overlay.isHiddenFromCapture)
        #expect(overlay.windowSharingType == NSWindow.SharingType.none)

        session.stop()
    }
}
