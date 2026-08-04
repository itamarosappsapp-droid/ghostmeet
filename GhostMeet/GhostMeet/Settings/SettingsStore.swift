//
//  SettingsStore.swift
//  GhostMeet
//

import Foundation
import Observation

/// Keychain accounts used by the app. Only provider keys ever go here.
nonisolated enum SecretAccount {
    /// API key of the LLM provider the user configured.
    static let llmProviderKey = "llm.provider.api-key"
}

/// User-scoped settings: the profile and the turn-segmentation thresholds.
///
/// Two invariants shape this type:
///
/// 1. **No secrets.** The provider key is never stored here, never cached in a
///    property, never written to `UserDefaults` and never put into a
///    description. It is read from, and written to, the `SecretStore` on
///    demand; the store only remembers *whether* one exists.
/// 2. **No session state.** Everything here belongs to the user, not to a call.
///    Clearing the conversation context resets `SessionEngine`'s transcript and
///    never reaches this store, which is what lets the profile outlive it.
///
/// The type is observable, so a change made in the settings screen is picked up
/// by the engine and the UI immediately — no restart, no "Apply" button.
@MainActor
@Observable
final class SettingsStore {

    /// Shared instance backed by the real keychain and the standard defaults.
    static let shared = SettingsStore()

    private enum DefaultsKey {
        static let profile = "settings.userProfile"
        static let turnSegmentation = "settings.turnSegmentation"
    }

    // MARK: - Persisted, user-scoped state

    /// Standing facts about the user. Survives both app restarts and clearing
    /// the conversation context.
    var profile: UserProfile {
        didSet { persist(profile, forKey: DefaultsKey.profile) }
    }

    /// Thresholds handed to `SessionEngine` as configuration.
    var turnSegmentation: TurnSegmentationSettings {
        didSet { persist(turnSegmentation, forKey: DefaultsKey.turnSegmentation) }
    }

    // MARK: - Secret status (never the secret itself)

    /// Whether a provider key is currently stored in the keychain.
    private(set) var hasProviderKey: Bool = false

    /// Human-readable description of the last keychain failure, or `nil`.
    /// Contains a status code only — never the key.
    private(set) var lastSecretError: String?

    // MARK: - Dependencies

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainHelper.shared
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.profile = Self.decode(UserProfile.self, from: defaults, key: DefaultsKey.profile)
            ?? .empty
        self.turnSegmentation = (Self.decode(
            TurnSegmentationSettings.self,
            from: defaults,
            key: DefaultsKey.turnSegmentation
        ) ?? .default).clamped()
        refreshProviderKeyPresence()
    }

    // MARK: - Provider key

    /// Reads the key straight from the keychain. Callers use it to build a
    /// request and drop it again; it is intentionally not cached.
    func providerKey() -> String? {
        do {
            let key = try secrets.secret(forAccount: SecretAccount.llmProviderKey)
            lastSecretError = nil
            return key
        } catch {
            report(error)
            return nil
        }
    }

    /// Stores the key in the keychain. Returns `false` when the keychain
    /// refused, in which case `lastSecretError` explains why.
    @discardableResult
    func setProviderKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeProviderKey() }
        return write(trimmed)
    }

    /// Deletes the key from the keychain.
    @discardableResult
    func removeProviderKey() -> Bool {
        write(nil)
    }

    private func write(_ key: String?) -> Bool {
        do {
            try secrets.setSecret(key, forAccount: SecretAccount.llmProviderKey)
            lastSecretError = nil
            hasProviderKey = key?.isEmpty == false
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func refreshProviderKeyPresence() {
        do {
            let key = try secrets.secret(forAccount: SecretAccount.llmProviderKey)
            hasProviderKey = key?.isEmpty == false
            lastSecretError = nil
        } catch {
            hasProviderKey = false
            report(error)
        }
    }

    /// Records a keychain failure for the UI. Only the error's own description
    /// is kept, which by construction carries a status code and nothing else.
    private func report(_ error: Error) {
        lastSecretError = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }

    // MARK: - Thresholds

    /// Puts every threshold back to the spec defaults.
    func resetTurnSegmentationToDefaults() {
        turnSegmentation = .default
    }

    // MARK: - Persistence

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from defaults: UserDefaults,
        key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension SettingsStore: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose: `SettingsStore` must be safe to print. The provider
    /// key is not part of this type's state and must never appear in a log.
    nonisolated var description: String {
        "SettingsStore(secrets: keychain-only, redacted)"
    }

    nonisolated var debugDescription: String { description }
}
