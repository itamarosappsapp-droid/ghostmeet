//
//  UpdateCheckTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Support

private let releasePage = URL(string: "https://github.com/slimgo/ghostmeet/releases/tag/v0.2.0")!

private func release(_ version: String, page: URL = releasePage) -> PublishedRelease {
    PublishedRelease(version: AppVersion(version)!, page: page)
}

/// A catalog that answers what the scenario says, and counts how many times it
/// was asked. The count is the whole point of one test: a check the user turned
/// off must make no request at all, not a request whose answer is discarded.
private final class SpyCatalog: ReleaseCatalog, @unchecked Sendable {

    private let lock = NSLock()
    private var asked = 0

    private let answer: PublishedRelease?
    private let failure: (any Error)?

    init(answer: PublishedRelease? = nil, failure: (any Error)? = nil) {
        self.answer = answer
        self.failure = failure
    }

    var timesAsked: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func latestRelease() async throws -> PublishedRelease? {
        lock.lock()
        asked += 1
        lock.unlock()
        if let failure { throw failure }
        return answer
    }
}

private struct Unreachable: Error {}

// MARK: - Версия

@Suite("Версия читается строго и отказывается гадать")
struct AppVersionParsingTests {

    @Test("Три числа — версия; тег с v тоже, потому что теги пишутся именно так")
    func parsesTheShapesTheProjectPublishes() {
        #expect(AppVersion("0.2.0") == AppVersion(major: 0, minor: 2, patch: 0))
        #expect(AppVersion("v0.2.0") == AppVersion(major: 0, minor: 2, patch: 0))
        #expect(AppVersion(" V1.2.3 ") == AppVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("Пред-релиз версией не считается: бета не предлагается идущему на собеседование")
    func refusesPreReleases() {
        #expect(AppVersion("0.3.0-beta1") == nil)
        #expect(AppVersion("v1.0.0-rc.1") == nil)
    }

    @Test("Две части, мусор и пустое — не версия, а повод промолчать")
    func refusesEverythingElse() {
        #expect(AppVersion("0.2") == nil)
        #expect(AppVersion("0.2.0.1") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v") == nil)
    }

    @Test("Сравнение идёт по старшинству частей, а не по строке")
    func ordersByComponents() {
        #expect(AppVersion("0.2.0")! > AppVersion("0.1.9")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("0.1.10")! > AppVersion("0.1.9")!)
        #expect(AppVersion("0.1.0")! == AppVersion("v0.1.0")!)
    }
}

// MARK: - Ответ GitHub

@Suite("Ответ GitHub разбирается — или не разбирается вовсе")
struct GitHubReleaseCatalogTests {

    @Test("Из ответа берутся тег и адрес страницы")
    func readsTagAndPage() throws {
        let payload = """
        {"tag_name": "v0.2.0", "html_url": "https://github.com/slimgo/ghostmeet/releases/tag/v0.2.0"}
        """
        let parsed = try #require(GitHubReleaseCatalog.release(from: Data(payload.utf8)))
        #expect(parsed.version == AppVersion(major: 0, minor: 2, patch: 0))
        #expect(parsed.page == releasePage)
    }

    @Test("Тег, который не разобрать, — это ничего, а не версия по умолчанию")
    func refusesAnUnparsableTag() {
        let payload = """
        {"tag_name": "nightly", "html_url": "https://github.com/slimgo/ghostmeet/releases"}
        """
        #expect(GitHubReleaseCatalog.release(from: Data(payload.utf8)) == nil)
    }

    @Test("Обрезанный или чужой JSON не роняет разбор")
    func survivesGarbage() {
        #expect(GitHubReleaseCatalog.release(from: Data("{\"tag_name\":".utf8)) == nil)
        #expect(GitHubReleaseCatalog.release(from: Data("[]".utf8)) == nil)
        #expect(GitHubReleaseCatalog.release(from: Data()) == nil)
    }
}

// MARK: - Решение показывать

@MainActor
@Suite("Уведомление появляется только когда есть что сказать")
struct UpdateCheckTests {

    @Test("Версия новее установленной — единственный случай, когда строка появляется")
    func announcesANewerRelease() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(answer: release("0.2.0")),
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { true }
        )

        await check.run()

        #expect(check.available?.version == AppVersion(major: 0, minor: 2, patch: 0))
        #expect(check.available?.page == releasePage)
    }

    @Test("Та же версия — молчание: «вы на последней» никто не спрашивал")
    func staysQuietOnTheSameVersion() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(answer: release("0.1.0")),
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { true }
        )

        await check.run()

        #expect(check.available == nil)
    }

    @Test("Сборка новее опубликованной молчит, а не зовёт откатиться назад")
    func staysQuietWhenRunningAheadOfTheRelease() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(answer: release("0.1.0")),
            runningVersion: AppVersion("0.2.0"),
            isEnabled: { true }
        )

        await check.run()

        #expect(check.available == nil)
    }

    @Test("Сеть недоступна — тишина, а не строка об ошибке в окне звонка")
    func swallowsFailures() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(failure: Unreachable()),
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { true }
        )

        await check.run()

        #expect(check.available == nil)
    }

    @Test("Релизов ещё нет — тоже тишина")
    func swallowsAnEmptyCatalog() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(answer: nil),
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { true }
        )

        await check.run()

        #expect(check.available == nil)
    }

    @Test("Выключенная проверка не делает запроса вовсе — это и есть смысл выключателя")
    func asksNothingWhenTurnedOff() async {
        let catalog = SpyCatalog(answer: release("0.2.0"))
        let check = UpdateCheck(
            catalog: catalog,
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { false }
        )

        await check.run()

        #expect(catalog.timesAsked == 0)
        #expect(check.available == nil)
    }

    @Test("Без своей версии сравнивать не с чем — и запрос не делается")
    func asksNothingWithoutItsOwnVersion() async {
        let catalog = SpyCatalog(answer: release("0.2.0"))
        let check = UpdateCheck(
            catalog: catalog,
            runningVersion: nil,
            isEnabled: { true }
        )

        await check.run()

        #expect(catalog.timesAsked == 0)
        #expect(check.available == nil)
    }

    @Test("Закрытая строка не возвращается сама")
    func dismissalClearsTheNotice() async {
        let check = UpdateCheck(
            catalog: SpyCatalog(answer: release("0.2.0")),
            runningVersion: AppVersion("0.1.0"),
            isEnabled: { true }
        )

        await check.run()
        #expect(check.available != nil)

        check.dismiss()

        #expect(check.available == nil)
    }
}

// MARK: - Настройка

@MainActor
@Suite("Проверка обновлений включена, пока её не выключили")
struct UpdateSettingTests {

    @Test("На чистой машине проверка включена: коллеге неоткуда узнать о новой сборке")
    func defaultsToOn() {
        let store = SettingsStore(defaults: throwawayDefaults(), secrets: InMemorySecretStore())

        #expect(store.checksForUpdates)
    }

    @Test("Выключенная проверка переживает перезапуск — иначе выключатель ничего не значит")
    func remembersBeingTurnedOff() {
        let defaults = throwawayDefaults()

        let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
        first.checksForUpdates = false

        let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())

        #expect(second.checksForUpdates == false)
    }

    /// A domain of its own per scenario: these tests write a flag, and the
    /// user's own settings are not theirs to touch.
    private func throwawayDefaults() -> UserDefaults {
        let name = "GhostMeetUpdateSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
