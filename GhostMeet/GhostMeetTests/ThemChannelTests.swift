//
//  ThemChannelTests.swift
//  GhostMeetTests
//

import CoreAudio
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A stand-in for `coreaudiod` and the window server: the test decides which
/// processes exist and which applications are running, and can replace both to
/// play out a restart.
private final class FakeProcessLister: AudioProcessLister, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AudioProcess]
    private var _applications: [RunningApplication]

    init(processes: [AudioProcess] = [], applications: [RunningApplication] = []) {
        self._processes = processes
        self._applications = applications
    }

    func audioProcesses() -> [AudioProcess] {
        lock.lock(); defer { lock.unlock() }
        return _processes
    }

    func runningApplications() -> [RunningApplication] {
        lock.lock(); defer { lock.unlock() }
        return _applications
    }

    func replace(processes: [AudioProcess], applications: [RunningApplication]) {
        lock.lock(); defer { lock.unlock() }
        _processes = processes
        _applications = applications
    }
}

// MARK: - Fixtures modelled on what the system actually reports

private enum Chrome {
    static let bundleID = "com.google.Chrome"
    static let bundleURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    static let helperExecutable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/150.0.7871.186/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")

    static func application(pid: pid_t = 14827) -> RunningApplication {
        RunningApplication(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            localizedName: "Google Chrome",
            isUserFacing: true
        )
    }

    /// The main browser process. Note it is *not* the one playing audio — the
    /// system reports the sound on a helper.
    static func mainProcess(objectID: AudioObjectID = 151, pid: pid_t = 14827) -> AudioProcess {
        AudioProcess(
            objectID: objectID,
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            // The main process runs from a code-signing clone, whose path holds
            // no `.app` component at all.
            executableURL: URL(fileURLWithPath: "/private/var/folders/hb/X/com.google.Chrome.code_sign_clone/clone.e3z/Google Chrome.app.bundle/Contents/MacOS/Google Chrome"),
            isPlayingAudio: false
        )
    }

    static func helper(
        objectID: AudioObjectID,
        pid: pid_t,
        isPlayingAudio: Bool = false
    ) -> AudioProcess {
        AudioProcess(
            objectID: objectID,
            processIdentifier: pid,
            bundleIdentifier: "com.google.Chrome.helper",
            executableURL: helperExecutable,
            isPlayingAudio: isPlayingAudio
        )
    }
}

/// A bare command-line player: no bundle identifier, no application behind it.
private func afplay(objectID: AudioObjectID = 165, pid: pid_t = 85885, playing: Bool = true) -> AudioProcess {
    AudioProcess(
        objectID: objectID,
        processIdentifier: pid,
        bundleIdentifier: "",
        executableURL: URL(fileURLWithPath: "/usr/bin/afplay"),
        isPlayingAudio: playing
    )
}

// MARK: - Разбор списка процессов

@Suite("Список приложений-источников")
struct SourceApplicationListingTests {

    @Test("Звук браузера отдаёт вспомогательный процесс — в списке всё равно один браузер")
    func browserHelpersFoldIntoTheBrowser() {
        let applications = SourceApplication.offered(
            processes: [
                Chrome.mainProcess(),
                Chrome.helper(objectID: 152, pid: 14881, isPlayingAudio: true),
                Chrome.helper(objectID: 153, pid: 14882),
            ],
            applications: [Chrome.application()]
        )

        #expect(applications.count == 1, "три процесса браузера — одна строка в списке")
        let chrome = try! #require(applications.first)
        #expect(chrome.name == "Google Chrome")
        #expect(chrome.isPlayingAudio, "звучит помощник — значит, звучит браузер")
        #expect(
            Set(chrome.processObjectIDs) == [151, 152, 153],
            "тапать надо все процессы приложения: неизвестно, какой из них зазвучит"
        )
    }

    @Test("Приложение можно выбрать, пока оно ещё молчит")
    func silentApplicationsAreStillOffered() {
        let applications = SourceApplication.offered(
            processes: [Chrome.mainProcess(), Chrome.helper(objectID: 152, pid: 14881)],
            applications: [Chrome.application()]
        )

        #expect(applications.map(\.name) == ["Google Chrome"])
        #expect(applications.first?.isPlayingAudio == false)
    }

    @Test("Фоновые службы не засоряют список, но звучащий процесс без приложения в него попадает")
    func onlyApplicationsAndAudibleProcessesAreOffered() {
        let daemon = AudioProcess(
            objectID: 137,
            processIdentifier: 1242,
            bundleIdentifier: "com.apple.CoreSpeech",
            executableURL: URL(fileURLWithPath: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"),
            isPlayingAudio: false
        )

        let applications = SourceApplication.offered(
            processes: [daemon, afplay(), Chrome.mainProcess()],
            applications: [Chrome.application()]
        )

        #expect(!applications.contains { $0.name == "corespeechd" }, "молчащая служба — не источник")
        #expect(applications.contains { $0.name == "afplay" }, "то, что звучит прямо сейчас, показать надо")
        #expect(applications.contains { $0.name == "Google Chrome" })
    }

    @Test("Звучащие приложения показываются первыми")
    func audibleApplicationsComeFirst() {
        let applications = SourceApplication.offered(
            processes: [Chrome.mainProcess(), afplay()],
            applications: [Chrome.application()]
        )

        #expect(applications.first?.name == "afplay")
    }

    @Test("Похожий идентификатор чужого приложения не присваивается браузеру")
    func aSeparateApplicationIsNotSwallowedByAPrefix() {
        let canary = RunningApplication(
            processIdentifier: 900,
            bundleIdentifier: "com.google.ChromeCanary",
            bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome Canary.app"),
            localizedName: "Google Chrome Canary"
        )
        let canaryProcess = AudioProcess(
            objectID: 200,
            processIdentifier: 900,
            bundleIdentifier: "com.google.ChromeCanary",
            executableURL: URL(fileURLWithPath: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary")
        )

        let applications = SourceApplication.offered(
            processes: [Chrome.mainProcess(), canaryProcess],
            applications: [Chrome.application(), canary]
        )

        #expect(applications.count == 2, "две разные программы должны остаться двумя строками")
    }

    @Test("Процесс без bundle-идентификатора опознаётся по исполняемому файлу")
    func bareProcessesAreIdentifiedByExecutable() {
        let applications = SourceApplication.offered(processes: [afplay()], applications: [])
        let player = try! #require(applications.first)

        #expect(player.name == "afplay")
        #expect(player.id == "/usr/bin/afplay")
    }
}

// MARK: - Устойчивость выбора

@Suite("Выбор приложения-источника переживает перезапуск")
struct SourceApplicationIdentityTests {

    @Test("После перезапуска браузера тот же выбор указывает на новые процессы")
    func selectionSurvivesRestartOfTheSourceApplication() {
        let before = SourceApplication.offered(
            processes: [
                Chrome.mainProcess(objectID: 151, pid: 14827),
                Chrome.helper(objectID: 152, pid: 14881, isPlayingAudio: true),
            ],
            applications: [Chrome.application(pid: 14827)]
        )
        let chosen = try! #require(before.first)

        // Браузер закрыли и открыли: и PID, и объекты Core Audio другие.
        let after = SourceApplication.offered(
            processes: [
                Chrome.mainProcess(objectID: 301, pid: 22001),
                Chrome.helper(objectID: 302, pid: 22004, isPlayingAudio: true),
            ],
            applications: [Chrome.application(pid: 22001)]
        )
        let resolved = try! #require(after.first { $0.id == chosen.id })

        #expect(resolved.id == chosen.id, "идентификатор выбора не должен зависеть от процессов")
        #expect(
            resolved.processObjectIDs != chosen.processObjectIDs,
            "а вот процессы обязаны быть новыми — иначе тап останется на мёртвых объектах"
        )
        #expect(Set(resolved.processObjectIDs) == [301, 302])
    }

    @Test("Пока приложение-источник закрыто, выбор ни к чему не приводится")
    func aClosedSourceApplicationResolvesToNothing() {
        let lister = FakeProcessLister(processes: [afplay()], applications: [])

        #expect(lister.resolveSourceApplication(id: Chrome.bundleID) == nil)
    }

    @Test("Источник только что перезапустился и ещё не зазвучал — он всё равно находится")
    func aJustRelaunchedSourceIsFoundBeforeItMakesASound() {
        // Процесс регистрируется в Core Audio на мгновение раньше, чем открывает
        // выход. Фильтр списка для выбора такой процесс прячет — и захват, если
        // искать через него, ждал бы источник, который уже вернулся.
        let silentAfterRelaunch = afplay(objectID: 400, pid: 90001, playing: false)
        let lister = FakeProcessLister(processes: [silentAfterRelaunch], applications: [])

        #expect(
            lister.sourceApplications().isEmpty,
            "в списке для выбора молчащего afplay быть не должно"
        )
        let resolved = try! #require(
            lister.resolveSourceApplication(id: "/usr/bin/afplay"),
            "а захват обязан его найти"
        )
        #expect(resolved.processObjectIDs == [400])
    }
}

// MARK: - Источник канала Them

@Suite("Канал Them за протоколом источника")
struct ThemCaptureServiceTests {

    @Test("Источник объявляет себя каналом Them, а не You")
    func theServiceBelongsToTheThemChannel() {
        let service = ProcessTapCaptureService(lister: FakeProcessLister())
        #expect(service.channel == .them)
    }

    @Test("Без выбранного приложения запуск не падает, а честно говорит, что канал молчит")
    func startingWithoutASourceIsNotAFailure() throws {
        let service = ProcessTapCaptureService(lister: FakeProcessLister())

        try service.start { _ in }

        #expect(service.isRunning, "микрофонный канал не должен страдать из-за незаполненного Them")
        #expect(service.status == .idle)
        service.stop()
        #expect(!service.isRunning)
    }

    @Test("Приложение-источник закрыто — захват сообщает о разрыве и ждёт возвращения")
    func aMissingSourceApplicationIsReportedHonestly() throws {
        let lister = FakeProcessLister(processes: [afplay()], applications: [])
        let service = ProcessTapCaptureService(sourceApplicationID: Chrome.bundleID, lister: lister)

        try service.start { _ in }
        defer { service.stop() }

        #expect(service.status == .waitingForSource(application: Chrome.bundleID))
        #expect(
            service.status.message.contains("вернётся"),
            "сообщение должно объяснять, что захват восстановится сам"
        )
    }

    @Test("Смена приложения-источника на лету не требует перезапуска сессии")
    func changingTheSourceApplicationTakesEffectAtOnce() throws {
        let lister = FakeProcessLister(processes: [afplay()], applications: [])
        let service = ProcessTapCaptureService(lister: lister)

        try service.start { _ in }
        defer { service.stop() }
        #expect(service.status == .idle)

        service.sourceApplicationID = Chrome.bundleID

        #expect(service.status == .waitingForSource(application: Chrome.bundleID))
    }

    @Test("Остановка возвращает источник в исходное состояние")
    func stoppingResetsTheStatus() throws {
        let lister = FakeProcessLister(processes: [afplay()], applications: [])
        let service = ProcessTapCaptureService(sourceApplicationID: Chrome.bundleID, lister: lister)

        try service.start { _ in }
        service.stop()

        #expect(service.status == .idle)
        #expect(!service.isRunning)
    }
}

// MARK: - Каталог для настроек

@Suite("Каталог приложений в настройках")
@MainActor
struct SourceApplicationCatalogTests {

    @Test("Каталог показывает то, что система сообщает прямо сейчас")
    func catalogReflectsTheSystem() {
        let lister = FakeProcessLister(
            processes: [Chrome.mainProcess(), Chrome.helper(objectID: 152, pid: 14881)],
            applications: [Chrome.application()]
        )
        let catalog = SourceApplicationCatalog(lister: lister)

        catalog.refresh()
        #expect(catalog.applications.map(\.name) == ["Google Chrome"])

        lister.replace(processes: [afplay()], applications: [])
        catalog.refresh()
        #expect(catalog.applications.map(\.name) == ["afplay"])
    }

    @Test("Закрытое приложение перестаёт находиться по своему идентификатору")
    func aClosedApplicationIsNoLongerFound() {
        let lister = FakeProcessLister(
            processes: [Chrome.mainProcess()],
            applications: [Chrome.application()]
        )
        let catalog = SourceApplicationCatalog(lister: lister)
        catalog.refresh()
        #expect(catalog.application(withID: Chrome.bundleID) != nil)

        lister.replace(processes: [], applications: [])
        catalog.refresh()

        #expect(catalog.application(withID: Chrome.bundleID) == nil)
        #expect(catalog.application(withID: nil) == nil)
    }
}

// MARK: - Хранение выбора

@MainActor
@Suite("Приложение-источник в настройках")
struct ThemSourceSettingsTests {

    private func withTemporaryDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
        let name = "GhostMeetThemSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            UserDefaults.standard.removeSuite(named: name)
        }
        return try body(defaults)
    }

    @Test("Свежее хранилище не навязывает источник")
    func freshStoreHasNoSource() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.themSourceApplicationID == nil)
        }
    }

    @Test("Выбранный браузер переживает перезапуск приложения")
    func chosenSourceSurvivesRestart() {
        withTemporaryDefaults { defaults in
            let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            first.themSourceApplicationID = "com.google.Chrome"

            let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(second.themSourceApplicationID == "com.google.Chrome")
        }
    }

    @Test("Сброс выбора стирает его и с диска")
    func clearingTheSourceRemovesIt() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.themSourceApplicationID = "com.google.Chrome"
            store.themSourceApplicationID = nil

            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.themSourceApplicationID == nil)
        }
    }
}
