//
//  AppDefaultsTests.swift
//  GhostMeetTests
//

import CoreGraphics
import Foundation
import Testing
@testable import GhostMeet

// MARK: - Support

/// Keys the app writes into its own domain. The scenarios below watch exactly
/// these: the overlay geometry the user dragged into place, and the settings
/// screen's own state.
private let watchedKeys = [
    "overlay.window.frame",
    "overlay.window.opacity",
    "settings.userProfile",
    "settings.turnSegmentation",
    "settings.speechModel"
]

/// What the given keys hold right now, in a form two snapshots can be compared by.
private func snapshot(_ defaults: UserDefaults, keys: [String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: keys.compactMap { key in
        defaults.object(forKey: key).map { (key, String(describing: $0)) }
    })
}

/// Runs `body` against a domain that belongs to nobody and wipes it afterwards.
private func withScratchDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetAppDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(defaults)
}

// MARK: - Scenarios

/// The app is its own test host: `xcodebuild test` launches `GhostMeet.app`, the
/// delegate runs its whole launch path and the overlay puts itself on screen.
/// These scenarios pin down the one consequence that must never follow from
/// that — the user comes back to the settings and the window position they left.
@MainActor
@Suite("Прогон тестов и настройки пользователя")
struct AppDefaultsTests {

    @Test("Приложение запущено тестовым раннером — это видно по окружению процесса")
    func aTestRunIsVisibleInTheProcessEnvironment() {
        #expect(
            AppDefaults.isRunningTests(),
            "этот код исполняется внутри прогона тестов; если признак перестал находиться, приложение снова пишет в настоящие настройки"
        )
        #expect(AppDefaults.isRunningTests(in: [
            "XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"
        ]))
        #expect(AppDefaults.isRunningTests(in: ["XCTestBundlePath": "/tmp/GhostMeetTests.xctest"]))
    }

    @Test("Приложение запущено пользователем — стораджи получают его настоящие настройки")
    func anOrdinaryLaunchKeepsTheRealDefaults() {
        #expect(AppDefaults.current(environment: [:]) === UserDefaults.standard)
        #expect(
            AppDefaults.current(environment: ["HOME": "/Users/someone", "LANG": "ru_RU.UTF-8"])
                === UserDefaults.standard,
            "обычное окружение не должно приниматься за тестовое"
        )
    }

    @Test("Приложение запущено тестами — стораджи получают одноразовое хранилище")
    func aTestRunGetsThrowawayDefaults() {
        #expect(AppDefaults.forCurrentProcess() !== UserDefaults.standard)
    }

    @Test("Прогон тестов не двигает сохранённую геометрию окна и не трогает настройки")
    func aTestRunLeavesTheUsersOwnDomainUntouched() {
        let usersOwn = UserDefaults.standard
        let before = snapshot(usersOwn, keys: watchedKeys)

        // Ровно то, что делает приложение на запуске: стораджи над выбранным
        // доменом, а дальше — обычная запись.
        let defaults = AppDefaults.forCurrentProcess()
        let windowState = WindowStateStore(defaults: defaults)
        let settings = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())

        let offScreen = CGRect(x: -4242, y: -4242, width: 420, height: 520)
        windowState.frame = offScreen
        windowState.opacity = 0.42
        settings.profile = UserProfile(role: "прогон тестов", experience: "", stack: "")
        settings.turnSegmentation.pauseThreshold = 1.9

        #expect(
            snapshot(usersOwn, keys: watchedKeys) == before,
            "прогон тестов переписал домен пользователя"
        )

        // …и при этом сохранение не сломано: одноразовое хранилище помнит то,
        // что в него записали.
        #expect(windowState.frame == offScreen)
        #expect(WindowStateStore(defaults: defaults).opacity == 0.42)
        #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            .turnSegmentation.pauseThreshold == 1.9)
    }

    @Test("Обычный запуск по-прежнему помнит геометрию окна и пороги между запусками")
    func anOrdinaryLaunchStillRestoresWhatItSaved() {
        withScratchDefaults { defaults in
            let placed = CGRect(x: 988, y: 286, width: 420, height: 520)
            let firstLaunch = WindowStateStore(defaults: defaults)
            firstLaunch.frame = placed
            firstLaunch.opacity = 0.75
            SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
                .turnSegmentation.pauseThreshold = 1.2

            // Вторые стораджи над тем же доменом — это следующий запуск.
            let nextLaunch = WindowStateStore(defaults: defaults)
            #expect(nextLaunch.frame == placed)
            #expect(nextLaunch.opacity == 0.75)
            #expect(SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
                .turnSegmentation.pauseThreshold == 1.2)
        }
    }

    @Test("Одноразовое хранилище пусто на каждом прогоне — прошлый прогон в него не протекает")
    func theThrowawayDomainStartsEmptyEveryRun() {
        AppDefaults.forCurrentProcess().set([-1.0, -1.0, 42.0, 42.0], forKey: "overlay.window.frame")

        // Следующий прогон получает домен заново.
        let nextRun = AppDefaults.forCurrentProcess()
        let leftovers = nextRun.persistentDomain(forName: AppDefaults.testRunSuiteName) ?? [:]
        #expect(leftovers.isEmpty, "прошлый прогон протёк в следующий")
        #expect(nextRun !== UserDefaults.standard)
    }
}
