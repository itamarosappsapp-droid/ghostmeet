//
//  ProviderSelectionTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

// MARK: - Хелперы

/// Прогоняет тест на выброшенном наборе настроек и на keychain в памяти —
/// ни один тест не трогает ни настройки пользователя, ни его реальные ключи.
@MainActor
private func withScratch<T>(
    _ body: (UserDefaults, InMemorySecretStore) throws -> T
) rethrows -> T {
    let name = "GhostMeetProviderSelectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(defaults, InMemorySecretStore())
}

/// Хранилище настроек на выброшенном наборе — для тестов, которым сам набор
/// больше не нужен.
@MainActor
private func scratchStore() -> SettingsStore {
    withScratch { defaults, secrets in
        SettingsStore(defaults: defaults, secrets: secrets)
    }
}

/// Всё, что сейчас видно через настройки, одной строкой. Нужно, чтобы буквально
/// проверить: ключа там нет.
private func defaultsDump(_ defaults: UserDefaults) -> String {
    defaults.dictionaryRepresentation()
        .map { key, value in
            if let data = value as? Data {
                return "\(key)=\(String(data: data, encoding: .utf8) ?? data.base64EncodedString())"
            }
            return "\(key)=\(value)"
        }
        .joined(separator: "\n")
}

/// Ждёт того, что происходит на следующем витке главного актора.
///
/// `followProviderSelection` перечитывает хранилище изнутри `Task`, поэтому
/// изменение видно не синхронно, а через хоп. Опрос лучше сна: тест кончается
/// сразу, как значение доехало.
@MainActor
private func eventually(_ condition: () -> Bool, attempts: Int = 200) async -> Bool {
    for _ in 0..<attempts {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

// MARK: - Выбор провайдера

@MainActor
@Suite("Выбор провайдера в настройках")
struct ProviderSelectionStorageTests {

    @Test("Свежие настройки стартуют с провайдера по умолчанию")
    func freshStoreUsesTheDefaultProvider() {
        withScratch { defaults, secrets in
            let store = SettingsStore(defaults: defaults, secrets: secrets)

            #expect(store.providerSelection == ProviderFactory.defaultSelection)
            #expect(store.providerPreset.id == ProviderFactory.defaultSelection.presetID)
        }
    }

    @Test("Выбор провайдера и переопределения переживают перезапуск")
    func selectionSurvivesRestart() {
        withScratch { defaults, secrets in
            let first = SettingsStore(defaults: defaults, secrets: secrets)
            first.providerSelection = ProviderSelection(
                presetID: "deepseek",
                baseURL: "https://llm.internal.test/v1",
                model: "internal-7b"
            )

            // Второе хранилище над тем же набором — это перезапуск приложения.
            let second = SettingsStore(defaults: defaults, secrets: secrets)
            #expect(second.providerSelection.presetID == "deepseek")
            #expect(second.providerSelection.baseURL == "https://llm.internal.test/v1")
            #expect(second.providerSelection.model == "internal-7b")
        }
    }

    @Test("Переопределённая команда CLI переживает перезапуск и разбирается на части")
    func commandOverrideSurvivesRestart() {
        withScratch { defaults, secrets in
            let first = SettingsStore(defaults: defaults, secrets: secrets)
            first.providerSelection = ProviderSelection(
                presetID: "claude-cli",
                commandOverride: "/opt/homebrew/bin/claude -p"
            )

            let second = SettingsStore(defaults: defaults, secrets: secrets)
            #expect(second.providerSelection.commandOverride == "/opt/homebrew/bin/claude -p")
            #expect(second.providerSelection.commandComponents == ["/opt/homebrew/bin/claude", "-p"])
        }
    }

    @Test("В настройках записан провайдер, которого больше нет — берётся провайдер по умолчанию")
    func unknownPresetFallsBackToTheDefault() {
        withScratch { defaults, secrets in
            defaults.set(
                try? JSONEncoder().encode(ProviderSelection(presetID: "atlantis")),
                forKey: "settings.providerSelection"
            )

            let store = SettingsStore(defaults: defaults, secrets: secrets)

            #expect(store.providerSelection.presetID == ProviderFactory.defaultSelection.presetID)
            #expect(ProviderFactory.preset(id: store.providerSelection.presetID) != nil)
        }
    }

    @Test("Любую предустановку из списка можно выбрать, и она превращается в провайдера")
    func everyPresetCanBeSelectedAndBuilt() throws {
        let store = scratchStore()
        #expect(Set(ProviderFactory.presets.map(\.id)).count == ProviderFactory.presets.count)

        for preset in ProviderFactory.presets {
            store.providerSelection = ProviderSelection(presetID: preset.id)

            let provider = try store.makeProvider()
            #expect(!provider.name.isEmpty)
            #expect(store.providerConfigurationError == nil, "«\(preset.name)» не собирается из коробки")
        }
    }

    @Test("Пустое переопределение означает «как в предустановке»")
    func blankOverridesFallBackToThePreset() throws {
        let store = scratchStore()
        store.providerSelection = ProviderSelection(presetID: "openai")

        let provider = try #require(try store.makeProvider() as? OpenAICompatibleProvider)
        let preset = try #require(ProviderFactory.preset(id: "openai"))

        #expect(provider.configuration.model == preset.defaultModel)
        #expect(provider.configuration.endpoint.absoluteString.hasPrefix(preset.defaultBaseURL))
    }

    @Test("Провайдера нет в списке — он достижим своим адресом и своей моделью")
    func typedOverridesReachAProviderNobodyListed() throws {
        let store = scratchStore()
        store.providerSelection = ProviderSelection(
            presetID: "openai",
            baseURL: "https://llm.internal.test/v1",
            model: "internal-7b"
        )

        let provider = try #require(try store.makeProvider() as? OpenAICompatibleProvider)

        #expect(provider.configuration.endpoint.host == "llm.internal.test")
        #expect(provider.configuration.model == "internal-7b")
    }

    @Test("Команда, вписанная в настройках, действительно запускается")
    func theTypedCommandIsWhatRuns() async throws {
        let store = scratchStore()
        // `/bin/cat` — честный дублёр инструмента: возвращает ровно то, что ему
        // отдали на вход. Если бы переопределение не доехало, запустился бы
        // `claude`, которого на машине сборки может и не быть.
        store.providerSelection = ProviderSelection(presetID: "claude-cli", commandOverride: "/bin/cat")

        let provider = try store.makeProvider()
        #expect(provider is CLIProvider)

        let request = SuggestionRequest(
            systemPrompt: "СИСТЕМНЫЙ-ПРОМПТ",
            userPrompt: "ВОПРОС-СОБЕСЕДНИКА",
            screenshot: nil,
            maxTokens: 512
        )
        var answer = ""
        for try await fragment in provider.stream(request) { answer += fragment }

        #expect(answer.contains("ВОПРОС-СОБЕСЕДНИКА"))
    }
}

// MARK: - Ключи

@MainActor
@Suite("Ключ свой на каждого провайдера")
struct ProviderKeyIsolationTests {

    private static let anthropicSecret = "sk-ant-DO-NOT-LEAK-0123456789"
    private static let openAISecret = "sk-oai-DO-NOT-LEAK-9876543210"

    @Test("Ключи двух провайдеров лежат рядом и не затирают друг друга")
    func keysOfTwoProvidersLiveSideBySide() {
        withScratch { defaults, secrets in
            let store = SettingsStore(defaults: defaults, secrets: secrets)
            store.providerSelection = ProviderSelection(presetID: "anthropic")
            #expect(store.setProviderKey(Self.anthropicSecret))

            // Переключились на другой сервис: чужой ключ не показывается …
            store.providerSelection = ProviderSelection(presetID: "openai")
            #expect(!store.hasProviderKey)
            #expect(store.providerKey() == nil)

            #expect(store.setProviderKey(Self.openAISecret))
            #expect(store.hasProviderKey)

            // … и ключ, оставшийся позади, цел.
            #expect(store.providerKey(forPresetID: "anthropic") == Self.anthropicSecret)
            #expect(store.providerKey(forPresetID: "openai") == Self.openAISecret)
            #expect(secrets.contents.count == 2, "два провайдера — две записи, а не одна общая")
        }
    }

    @Test("Возврат к прежнему провайдеру не требует вводить ключ заново")
    func comingBackToAProviderFindsItsKeyInPlace() {
        withScratch { defaults, secrets in
            let store = SettingsStore(defaults: defaults, secrets: secrets)
            store.setProviderKey(Self.anthropicSecret)

            store.providerSelection = ProviderSelection(presetID: "openai")
            store.setProviderKey(Self.openAISecret)
            store.providerSelection = ProviderSelection(presetID: "anthropic")

            #expect(store.hasProviderKey)
            #expect(store.providerKey() == Self.anthropicSecret)
        }
    }

    @Test("Удаление ключа одного провайдера не трогает остальные")
    func removingOneKeyLeavesTheOthersAlone() {
        withScratch { defaults, secrets in
            let store = SettingsStore(defaults: defaults, secrets: secrets)
            store.setProviderKey(Self.anthropicSecret)
            store.providerSelection = ProviderSelection(presetID: "openai")
            store.setProviderKey(Self.openAISecret)

            #expect(store.removeProviderKey())

            #expect(!store.hasProviderKey)
            #expect(store.providerKey() == nil)
            #expect(store.providerKey(forPresetID: "anthropic") == Self.anthropicSecret)
        }
    }

    @Test("Ключи переживают перезапуск, каждый на своём месте")
    func keysSurviveRestartOnTheirOwnAccounts() {
        withScratch { defaults, secrets in
            let first = SettingsStore(defaults: defaults, secrets: secrets)
            first.setProviderKey(Self.anthropicSecret)
            first.providerSelection = ProviderSelection(presetID: "openai")
            first.setProviderKey(Self.openAISecret)

            let second = SettingsStore(defaults: defaults, secrets: secrets)
            #expect(second.providerSelection.presetID == "openai")
            #expect(second.hasProviderKey)
            #expect(second.providerKey() == Self.openAISecret)
            #expect(second.providerKey(forPresetID: "anthropic") == Self.anthropicSecret)
        }
    }

    @Test("Ни один ключ не попадает в настройки, файлы и логи")
    func noProviderKeyReachesSettingsOrLogs() {
        withScratch { defaults, secrets in
            let store = SettingsStore(defaults: defaults, secrets: secrets)
            store.profile = UserProfile(role: "Backend", experience: "6 лет", stack: "Go")
            store.setProviderKey(Self.anthropicSecret)
            store.providerSelection = ProviderSelection(
                presetID: "openai",
                baseURL: "https://llm.internal.test/v1",
                model: "internal-7b"
            )
            store.setProviderKey(Self.openAISecret)

            let dump = defaultsDump(defaults)
            #expect(!dump.contains(Self.anthropicSecret))
            #expect(!dump.contains(Self.openAISecret))
            #expect(!dump.lowercased().contains("api-key"))
            // Выбор и переопределения в настройках действительно есть — значит,
            // проверка выше проходит не потому, что туда вообще ничего не пишут.
            #expect(dump.contains("llm.internal.test"))
            #expect(dump.contains("Backend"))

            #expect(!String(describing: store).contains(Self.anthropicSecret))
            #expect(!String(reflecting: store).contains(Self.openAISecret))
        }
    }

    @Test("Ключ, сохранённый прежней версией, переезжает на выбранного провайдера")
    func theLegacySharedKeyIsMigrated() {
        withScratch { defaults, _ in
            let seeded = InMemorySecretStore(
                storage: [SecretAccount.legacyLLMProviderKey: Self.anthropicSecret]
            )

            let store = SettingsStore(defaults: defaults, secrets: seeded)

            #expect(store.hasProviderKey, "обновление приложения не должно выглядеть как потеря ключа")
            #expect(store.providerKey() == Self.anthropicSecret)
            #expect(seeded.contents[SecretAccount.legacyLLMProviderKey] == nil)
            #expect(
                seeded.contents[SecretAccount.llmProviderKey(presetID: "anthropic")]
                    == Self.anthropicSecret
            )
        }
    }

    @Test("Локальным серверам и CLI ключ не нужен, облачным — нужен")
    func onlyCloudProvidersAskForAKey() {
        let store = scratchStore()

        for id in ["ollama", "lmstudio", "llamacpp", "claude-cli", "codex-cli", "kimi-cli"] {
            store.providerSelection = ProviderSelection(presetID: id)
            #expect(!store.providerRequiresKey, "«\(id)» не должен просить ключ")
        }

        for id in ["anthropic", "openai", "gemini", "openrouter", "polza", "deepseek", "kimi"] {
            store.providerSelection = ProviderSelection(presetID: id)
            #expect(store.providerRequiresKey, "«\(id)» без ключа не ответит")
        }
    }
}

// MARK: - Возможности провайдера

@MainActor
@Suite("Экран честно показывает возможности провайдера")
struct ProviderCapabilityNoticeTests {

    @Test("Мультимодальный провайдер обещает скриншот")
    func aMultimodalProviderPromisesTheScreenshot() {
        let store = scratchStore()
        store.providerSelection = ProviderSelection(presetID: "anthropic")

        #expect(store.providerAcceptsImages)
        #expect(store.providerCapabilityNote.contains("скриншот"))
        #expect(!store.providerCapabilityNote.contains("слабее"))
    }

    @Test("Текстовый провайдер предупреждает, что «Решить с экрана» работает слабее")
    func aTextOnlyProviderWarnsAboutSolveOnScreen() {
        let store = scratchStore()
        store.providerSelection = ProviderSelection(presetID: "deepseek")

        #expect(!store.providerAcceptsImages)
        let note = store.providerCapabilityNote
        #expect(note.contains("Решить с экрана"))
        #expect(note.contains("слабее"))
        #expect(note.contains("не отправляется"))
    }

    @Test("CLI и локальные серверы честно объявлены текстовыми")
    func cliAndLocalServersAreDeclaredTextOnly() {
        let store = scratchStore()

        for id in ["claude-cli", "codex-cli", "kimi-cli", "ollama", "lmstudio", "llamacpp"] {
            store.providerSelection = ProviderSelection(presetID: id)
            #expect(!store.providerAcceptsImages, "«\(id)» не принимает изображения")
        }
    }

    @Test("Обещание экрана совпадает с тем, что умеет собранный провайдер")
    func theScreenAgreesWithTheProviderItBuilds() throws {
        let store = scratchStore()

        for preset in ProviderFactory.presets {
            store.providerSelection = ProviderSelection(presetID: preset.id)
            let provider = try store.makeProvider()

            #expect(
                store.providerAcceptsImages == provider.capabilities.acceptsImages,
                "экран обещает про «\(preset.name)» не то, что делает провайдер"
            )
        }
    }
}

// MARK: - Применение без перезапуска

@MainActor
@Suite("Смена провайдера применяется без перезапуска")
struct ProviderHotSwapTests {

    @Test("Выбранный провайдер применяется к движку сразу при подписке")
    func theSelectedProviderIsAppliedOnSubscription() {
        let settings = scratchStore()
        settings.providerSelection = ProviderSelection(presetID: "openai")
        let controller = SessionController(engine: SessionEngine())

        controller.followProviderSelection(of: settings)

        #expect(controller.engine.provider is OpenAICompatibleProvider)
        #expect(controller.engine.provider?.name == "OpenAI")
    }

    @Test("Пользователь сменил провайдера во время звонка — движок увидел это без перезапуска")
    func aProviderChangedMidCallReachesTheEngine() async {
        let settings = scratchStore()
        let controller = SessionController(engine: SessionEngine())
        controller.followProviderSelection(of: settings)
        #expect(controller.engine.provider is ClaudeProvider)

        settings.providerSelection = ProviderSelection(presetID: "gemini")

        let arrived = await eventually { controller.engine.provider is GeminiProvider }
        #expect(arrived, "смена провайдера не доехала до движка — подписка развалилась")
    }

    @Test("Провайдера меняли несколько раз подряд — движок следует за каждым изменением")
    func theEngineKeepsFollowingAfterTheFirstChange() async {
        let settings = scratchStore()
        let controller = SessionController(engine: SessionEngine())
        controller.followProviderSelection(of: settings)

        // Подписка пересоздаётся на каждом изменении, поэтому регрессия здесь
        // выглядит так: первое переключение проходит, второе молча теряется.
        for (id, name) in [
            ("ollama", "Ollama (локально)"),
            ("claude-cli", "Claude CLI"),
            ("anthropic", "Claude")
        ] {
            settings.providerSelection = ProviderSelection(presetID: id)
            let arrived = await eventually { controller.engine.provider?.name == name }
            #expect(arrived, "движок перестал следовать за настройками на «\(id)»")
        }
    }

    @Test("Правка модели тоже доезжает до движка")
    func editingTheModelReachesTheEngineToo() async {
        let settings = scratchStore()
        settings.providerSelection = ProviderSelection(presetID: "openai")
        let controller = SessionController(engine: SessionEngine())
        controller.followProviderSelection(of: settings)

        settings.providerSelection.model = "gpt-experimental"

        let arrived = await eventually {
            (controller.engine.provider as? OpenAICompatibleProvider)?.configuration.model
                == "gpt-experimental"
        }
        #expect(arrived)
    }

    @Test("Недописанный адрес не оставляет сессию без модели")
    func aHalfTypedAddressKeepsThePreviousProvider() async {
        let settings = scratchStore()
        settings.providerSelection = ProviderSelection(presetID: "openai")
        let controller = SessionController(engine: SessionEngine())
        controller.followProviderSelection(of: settings)

        // Пользователь правит поле прямо во время звонка: промежуточное
        // состояние не должно выключать подсказки.
        settings.providerSelection.baseURL = "просто текст"

        for _ in 0..<20 { await Task.yield() }

        #expect(settings.providerConfigurationError != nil, "экран обязан объяснить, что не так")
        #expect(
            (controller.engine.provider as? OpenAICompatibleProvider)?.configuration.endpoint.host
                == "api.openai.com",
            "прежний провайдер должен остаться на месте"
        )
    }

    @Test("Сессия собирается через фабрику: выбран не Claude — Claude и не создаётся")
    func theSessionIsBuiltThroughTheFactory() {
        let settings = scratchStore()
        settings.providerSelection = ProviderSelection(presetID: "kimi")

        let controller = SessionController.dualChannel(
            settings: settings,
            recognizer: StubSpeechRecognizer()
        )

        #expect(controller.engine.provider is OpenAICompatibleProvider)
        #expect(!(controller.engine.provider is ClaudeProvider))
        #expect(controller.engine.provider?.name == "Kimi (Moonshot)")
    }
}
