import Foundation
import Security
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A `SecretStore` that always fails, to check that a keychain refusal is
/// surfaced instead of silently swallowed.
private final class FailingSecretStore: SecretStore, @unchecked Sendable {
    func secret(forAccount account: String) throws -> String? {
        throw SecretStoreError.unexpectedStatus(errSecInteractionNotAllowed)
    }

    func setSecret(_ secret: String?, forAccount account: String) throws {
        throw SecretStoreError.unexpectedStatus(errSecInteractionNotAllowed)
    }
}

/// Stand-in for the session-scoped conversation state that `SessionEngine`
/// owns. The point of the profile tests is that clearing it goes nowhere near
/// `SettingsStore`.
@MainActor
private final class ConversationContextStub {
    private(set) var turns: [String] = []

    func append(_ turn: String) { turns.append(turn) }

    /// The "clear conversation context" action from the spec.
    func clear() { turns.removeAll() }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs `body` against a throwaway `UserDefaults` suite and wipes it afterwards,
/// so tests never touch the user's real preferences.
@MainActor
private func withTemporaryDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(defaults)
}

/// Every value currently visible through the given defaults, flattened to text.
/// Used to assert, literally, that a secret is nowhere in there.
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

// MARK: - Thresholds

@MainActor
@Suite("Пороги нарезки реплик")
struct SettingsTurnSegmentationTests {

    @Test("Порог паузы поднят: он больше не входит ни в какой бюджет задержки")
    func theDefaultPauseThresholdIsNoLongerALatencyCompromise() {
        let settings = TurnSegmentationConfig.default

        #expect(settings.pauseThreshold == 1.5)
        #expect(
            TurnSegmentationConfig.pauseThresholdRange.contains(settings.pauseThreshold),
            "ползунок в настройках обязан допускать значение по умолчанию"
        )
        #expect(
            settings.pauseThreshold < settings.safetyFlushInterval / 3,
            "иначе реплики режет таймер, а не тишина"
        )
        #expect(TurnSegmentationConfig.minimumTurnDurationRange.contains(settings.minimumTurnDuration))
        #expect((0.5...0.8).contains(settings.minimumTurnDuration))
        #expect(settings.safetyFlushInterval == 10)
        #expect(settings.silenceGateRMS > 0)
    }

    @Test("Пороги переживают запись и чтение, а служебный тик движка не сохраняется")
    func thresholdsSurviveStorageWithoutEngineInternals() {
        let tuned = TurnSegmentationConfig(
            pauseThreshold: 1.2,
            minimumTurnDuration: 0.5,
            silenceGateRMS: 0.05,
            safetyFlushInterval: 15,
            pauseCheckInterval: 0.42
        )

        let stored = try! JSONEncoder().encode(tuned)
        let restored = try! JSONDecoder().decode(TurnSegmentationConfig.self, from: stored)

        // Everything the user tunes survives the round trip …
        #expect(restored.pauseThreshold == 1.2)
        #expect(restored.minimumTurnDuration == 0.5)
        #expect(restored.safetyFlushInterval == 15)
        #expect(restored.silenceGateRMS == 0.05)

        // … while the engine's internal tick is never persisted, so a
        // hand-edited preferences file cannot stall the pipeline with it.
        #expect(restored.pauseCheckInterval == TurnSegmentationConfig.default.pauseCheckInterval)
        let asText = String(data: stored, encoding: .utf8) ?? ""
        #expect(!asText.contains("pauseCheckInterval"))
    }

    @Test("Свежее хранилище отдаёт пороги по умолчанию")
    func freshStoreUsesDefaults() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.turnSegmentation == .default)
        }
    }

    @Test("Изменённые пороги переживают перезапуск приложения")
    func thresholdsSurviveRestart() {
        withTemporaryDefaults { defaults in
            let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            first.turnSegmentation.pauseThreshold = 1.2
            first.turnSegmentation.minimumTurnDuration = 0.5
            first.turnSegmentation.safetyFlushInterval = 15
            first.turnSegmentation.silenceGateRMS = 0.05

            // A second store over the same defaults stands in for a relaunch.
            let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(second.turnSegmentation.pauseThreshold == 1.2)
            #expect(second.turnSegmentation.minimumTurnDuration == 0.5)
            #expect(second.turnSegmentation.safetyFlushInterval == 15)
            #expect(second.turnSegmentation.silenceGateRMS == 0.05)
        }
    }

    @Test("Сброс возвращает значения по умолчанию")
    func resetRestoresDefaults() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.turnSegmentation.pauseThreshold = 1.9
            store.resetTurnSegmentationToDefaults()

            #expect(store.turnSegmentation == .default)
            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.turnSegmentation == .default)
        }
    }

    @Test("Значения вне допустимого диапазона подрезаются при загрузке")
    func decodedThresholdsAreClamped() {
        withTemporaryDefaults { defaults in
            let broken = TurnSegmentationConfig(
                pauseThreshold: 0,
                minimumTurnDuration: 99,
                silenceGateRMS: -1,
                safetyFlushInterval: 0
            )
            defaults.set(try? JSONEncoder().encode(broken), forKey: "settings.turnSegmentation")

            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.turnSegmentation.pauseThreshold == TurnSegmentationConfig.pauseThresholdRange.lowerBound)
            #expect(store.turnSegmentation.minimumTurnDuration == TurnSegmentationConfig.minimumTurnDurationRange.upperBound)
            #expect(store.turnSegmentation.safetyFlushInterval == TurnSegmentationConfig.safetyFlushIntervalRange.lowerBound)
            #expect(store.turnSegmentation.silenceGateRMS == TurnSegmentationConfig.silenceGateRMSRange.lowerBound)
        }
    }

    @Test("Изменение порога видно наблюдателю сразу, без перезапуска")
    func thresholdChangeIsObservable() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let notified = Box(false)

            withObservationTracking {
                _ = store.turnSegmentation
            } onChange: {
                notified.value = true
            }

            store.turnSegmentation.pauseThreshold = 1.1
            #expect(notified.value)
        }
    }
}

// MARK: - Profile

@MainActor
@Suite("Профиль пользователя")
struct SettingsUserProfileTests {

    @Test("Пустой профиль не даёт мусора в промпте")
    func emptyProfileHasEmptyFragment() {
        #expect(UserProfile.empty.isEmpty)
        #expect(UserProfile.empty.promptFragment.isEmpty)
        #expect(UserProfile(role: "   ", experience: "\n", stack: "").isEmpty)
    }

    @Test("Заполненные поля попадают в фрагмент промпта, пустые — нет")
    func promptFragmentSkipsBlankFields() {
        let profile = UserProfile(role: "Backend-разработчик", experience: "", stack: "Go, PostgreSQL")
        let fragment = profile.promptFragment

        #expect(fragment.contains("Backend-разработчик"))
        #expect(fragment.contains("Go, PostgreSQL"))
        #expect(!fragment.contains("Опыт"))
    }

    @Test("Профиль сохраняется между запусками")
    func profileSurvivesRestart() {
        withTemporaryDefaults { defaults in
            let first = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            first.profile = UserProfile(
                role: "Backend-разработчик",
                experience: "6 лет, финтех",
                stack: "Go, PostgreSQL, Kubernetes"
            )

            let second = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(second.profile.role == "Backend-разработчик")
            #expect(second.profile.experience == "6 лет, финтех")
            #expect(second.profile.stack == "Go, PostgreSQL, Kubernetes")
        }
    }

    @Test("Очистка контекста разговора не стирает профиль")
    func profileSurvivesConversationContextClear() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.profile = UserProfile(role: "SRE", experience: "10 лет", stack: "Terraform")

            let conversation = ConversationContextStub()
            conversation.append("Them: расскажите о себе")
            conversation.append("You: я SRE")

            conversation.clear()

            #expect(conversation.turns.isEmpty)
            #expect(store.profile == UserProfile(role: "SRE", experience: "10 лет", stack: "Terraform"))
            // And it is still on disk, not merely in memory.
            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.profile.role == "SRE")
        }
    }

    @Test("Изменение профиля видно наблюдателю сразу")
    func profileChangeIsObservable() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let notified = Box(false)

            withObservationTracking {
                _ = store.profile
            } onChange: {
                notified.value = true
            }

            store.profile.role = "iOS-разработчик"
            #expect(notified.value)
        }
    }
}

// MARK: - Provider key

@MainActor
@Suite("Ключ провайдера")
struct SettingsProviderKeyTests {

    private static let secret = "sk-test-DO-NOT-LEAK-0123456789"

    @Test("Ключ сохраняется в защищённое хранилище и читается обратно")
    func keyRoundTripsThroughSecretStore() {
        withTemporaryDefaults { defaults in
            let secrets = InMemorySecretStore()
            let store = SettingsStore(defaults: defaults, secrets: secrets)

            #expect(!store.hasProviderKey)
            #expect(store.setProviderKey(Self.secret))
            #expect(store.hasProviderKey)
            #expect(store.providerKey() == Self.secret)
            // Аккаунт в Keychain — идентификатор провайдера, а не один общий.
            #expect(
                secrets.contents[SecretAccount.llmProviderKey(presetID: store.providerSelection.presetID)]
                    == Self.secret
            )
        }
    }

    @Test("Сохранённый ключ доступен после перезапуска, но живёт только в Keychain")
    func keyIsReadBackAfterRestart() {
        withTemporaryDefaults { defaults in
            let secrets = InMemorySecretStore()
            SettingsStore(defaults: defaults, secrets: secrets).setProviderKey(Self.secret)

            let reloaded = SettingsStore(defaults: defaults, secrets: secrets)
            #expect(reloaded.hasProviderKey)
            #expect(reloaded.providerKey() == Self.secret)
        }
    }

    @Test("Ключ не попадает в UserDefaults")
    func keyNeverReachesUserDefaults() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.profile = UserProfile(role: "Backend", experience: "6 лет", stack: "Go")
            store.turnSegmentation.pauseThreshold = 1.0
            store.setProviderKey(Self.secret)

            let dump = defaultsDump(defaults)
            #expect(!dump.contains(Self.secret))
            #expect(!dump.lowercased().contains("api-key"))
            // The non-secret settings really are in there — the sweep above is
            // not passing merely because nothing was written.
            #expect(dump.contains("Backend"))
        }
    }

    @Test("Ключ не попадает в описание хранилища, которое может уйти в лог")
    func keyNeverReachesDescriptions() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.setProviderKey(Self.secret)

            #expect(!String(describing: store).contains(Self.secret))
            #expect(!String(reflecting: store).contains(Self.secret))
        }
    }

    @Test("Ошибка Keychain не раскрывает ключ и попадает в состояние для UI")
    func keychainFailureIsSurfacedWithoutTheKey() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: FailingSecretStore())

            #expect(!store.setProviderKey(Self.secret))
            #expect(!store.hasProviderKey)
            #expect(store.lastSecretError != nil)
            #expect(store.lastSecretError?.contains(Self.secret) == false)
        }
    }

    @Test("Удаление ключа очищает хранилище")
    func removingKeyClearsSecretStore() {
        withTemporaryDefaults { defaults in
            let secrets = InMemorySecretStore()
            let store = SettingsStore(defaults: defaults, secrets: secrets)
            store.setProviderKey(Self.secret)

            #expect(store.removeProviderKey())
            #expect(!store.hasProviderKey)
            #expect(store.providerKey() == nil)
            #expect(secrets.contents.isEmpty)
        }
    }

    @Test("Пустой ввод не сохраняет пустой ключ")
    func blankKeyIsNotStored() {
        withTemporaryDefaults { defaults in
            let secrets = InMemorySecretStore()
            let store = SettingsStore(defaults: defaults, secrets: secrets)

            store.setProviderKey("   \n ")
            #expect(!store.hasProviderKey)
            #expect(secrets.contents.isEmpty)
        }
    }
}
