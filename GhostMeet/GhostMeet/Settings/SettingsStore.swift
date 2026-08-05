//
//  SettingsStore.swift
//  GhostMeet
//

import Foundation
import Observation

/// Keychain accounts used by the app. Only provider keys ever go here.
nonisolated enum SecretAccount {

    /// Account holding the API key of **one** provider.
    ///
    /// Keyed by `ProviderPreset.id` on purpose. A single shared account would
    /// mean that switching from OpenAI to Anthropic overwrote the key left
    /// behind, and switching back would silently ask for it again — a keychain
    /// entry per provider is what lets several of them lie side by side.
    static func llmProviderKey(presetID: String) -> String {
        "llm.provider.\(presetID).api-key"
    }

    /// The one account used before keys became per-provider. Read once at
    /// startup and moved onto the selected provider, so that upgrading the app
    /// does not look like the key vanished.
    static let legacyLLMProviderKey = "llm.provider.api-key"
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
        static let speechModel = "settings.speechModel"
        static let themSourceApplication = "settings.themSourceApplication"
        static let providerSelection = "settings.providerSelection"
    }

    // MARK: - Persisted, user-scoped state

    /// Standing facts about the user. Survives both app restarts and clearing
    /// the conversation context.
    var profile: UserProfile {
        didSet { persist(profile, forKey: DefaultsKey.profile) }
    }

    /// Thresholds handed to `SessionEngine` as configuration.
    var turnSegmentation: TurnSegmentationConfig {
        didSet { persist(turnSegmentation, forKey: DefaultsKey.turnSegmentation) }
    }

    /// Which local model recognises speech. Belongs to the user rather than to a
    /// call: the model is downloaded once and reused across every session, so a
    /// choice made before an interview must still be there at the next one.
    var speechModel: WhisperModel {
        didSet { persist(speechModel, forKey: DefaultsKey.speechModel) }
    }

    /// Stable id of the application whose sound becomes the `Them` channel, or
    /// `nil` while none has been picked.
    ///
    /// An id and not a process: a browser plays the call from a helper process
    /// that gets a new PID on every launch, so anything narrower than the
    /// application would stop pointing at it after the first restart. Persisted
    /// because the same browser is used call after call — this is picked once,
    /// not before every interview.
    var themSourceApplicationID: String? {
        didSet {
            if let id = themSourceApplicationID, !id.isEmpty {
                defaults.set(id, forKey: DefaultsKey.themSourceApplication)
            } else {
                defaults.removeObject(forKey: DefaultsKey.themSourceApplication)
            }
        }
    }

    /// Which model answers, plus the overrides the user typed over the preset.
    ///
    /// Only the choice is here — never the key, which stays in the keychain
    /// under an account of its own. Persisted whole, so base URL, model and CLI
    /// command survive a restart together with the provider they belong to.
    var providerSelection: ProviderSelection {
        didSet {
            persist(providerSelection, forKey: DefaultsKey.providerSelection)
            // Every provider has its own key, so moving to another one changes
            // which keychain entry the screen is talking about.
            if providerSelection.presetID != oldValue.presetID {
                refreshProviderKeyPresence()
            }
        }
    }

    /// The preset behind the current selection, with its transport, defaults
    /// and — the part the settings screen must not lie about — its capabilities.
    var providerPreset: ProviderPreset {
        ProviderFactory.preset(id: providerSelection.presetID) ?? Self.fallbackPreset
    }

    /// Whether the screen has to ask for a key at all. False for local servers
    /// and for CLI tools, which authenticate themselves.
    var providerRequiresKey: Bool { providerPreset.needsKey }

    /// Whether a screenshot may ride along with a request.
    var providerAcceptsImages: Bool { providerPreset.capabilities.acceptsImages }

    /// What the screen tells the user about the chosen provider's reach.
    ///
    /// Lives here rather than in the view because it is a statement about the
    /// product's primary mode, not a caption: with a text-only provider `Solve
    /// on screen` reasons over recognised text alone, and the user has to learn
    /// that when picking, not when the answer turns out to be worse.
    var providerCapabilityNote: String {
        providerAcceptsImages
            ? "Провайдер принимает изображения: режим «Решить с экрана» получает сам скриншот."
            : "Провайдер только текстовый: скриншот не отправляется, и режим «Решить с экрана» работает слабее — по распознанному тексту с экрана."
    }

    /// The reason the current selection cannot be turned into a provider, in
    /// words meant for the user — a mistyped base URL, an emptied model.
    ///
    /// Built by trying the real thing rather than by validating separately, so
    /// the screen cannot say "fine" about a selection the session would refuse.
    var providerConfigurationError: String? {
        do {
            _ = try makeProvider()
            return nil
        } catch let failure as LLMFailure {
            return failure.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Used when a hand-edited preferences file names a provider that no longer
    /// exists: the app falls back to the shipped default instead of ending up
    /// with no provider at all.
    private static var fallbackPreset: ProviderPreset {
        ProviderFactory.preset(id: ProviderFactory.defaultSelection.presetID)
            ?? ProviderFactory.presets[0]
    }

    // MARK: - Secret status (never the secret itself)

    /// Whether a key is stored for the **currently selected** provider. Keys of
    /// the other providers stay where they are and are not reflected here.
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
            TurnSegmentationConfig.self,
            from: defaults,
            key: DefaultsKey.turnSegmentation
        ) ?? .default).clamped()
        // An unknown or hand-edited value falls back to the default instead of
        // leaving the app with no model at all.
        self.speechModel = Self.decode(WhisperModel.self, from: defaults, key: DefaultsKey.speechModel)
            ?? .default
        self.themSourceApplicationID = defaults.string(forKey: DefaultsKey.themSourceApplication)
        // A selection naming a provider that has since been removed falls back
        // to the default rather than leaving the app pointed at nothing.
        let stored = Self.decode(ProviderSelection.self, from: defaults, key: DefaultsKey.providerSelection)
        self.providerSelection = stored.flatMap { selection in
            ProviderFactory.preset(id: selection.presetID) == nil ? nil : selection
        } ?? ProviderFactory.defaultSelection
        migrateLegacyProviderKeyIfNeeded()
        refreshProviderKeyPresence()
    }

    // MARK: - Provider key

    /// Reads the key of the currently selected provider straight from the
    /// keychain. Callers use it to build a request and drop it again; it is
    /// intentionally not cached.
    func providerKey() -> String? {
        providerKey(forPresetID: providerSelection.presetID)
    }

    /// Reads the key of one particular provider — the form the isolation
    /// between them is actually built on.
    func providerKey(forPresetID presetID: String) -> String? {
        do {
            let key = try secrets.secret(forAccount: SecretAccount.llmProviderKey(presetID: presetID))
            lastSecretError = nil
            return key
        } catch {
            report(error)
            return nil
        }
    }

    /// Stores the key of the currently selected provider. Returns `false` when
    /// the keychain refused, in which case `lastSecretError` explains why.
    @discardableResult
    func setProviderKey(_ key: String) -> Bool {
        setProviderKey(key, forPresetID: providerSelection.presetID)
    }

    @discardableResult
    func setProviderKey(_ key: String, forPresetID presetID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeProviderKey(forPresetID: presetID) }
        return write(trimmed, forPresetID: presetID)
    }

    /// Deletes the key of the currently selected provider, leaving every other
    /// provider's key untouched.
    @discardableResult
    func removeProviderKey() -> Bool {
        removeProviderKey(forPresetID: providerSelection.presetID)
    }

    @discardableResult
    func removeProviderKey(forPresetID presetID: String) -> Bool {
        write(nil, forPresetID: presetID)
    }

    private func write(_ key: String?, forPresetID presetID: String) -> Bool {
        do {
            try secrets.setSecret(key, forAccount: SecretAccount.llmProviderKey(presetID: presetID))
            lastSecretError = nil
            if presetID == providerSelection.presetID {
                hasProviderKey = key?.isEmpty == false
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func refreshProviderKeyPresence() {
        do {
            let account = SecretAccount.llmProviderKey(presetID: providerSelection.presetID)
            hasProviderKey = try secrets.secret(forAccount: account)?.isEmpty == false
            lastSecretError = nil
        } catch {
            hasProviderKey = false
            report(error)
        }
    }

    /// Moves a key written by a build that kept one shared account onto the
    /// selected provider.
    ///
    /// Without this the upgrade reads as data loss: the key is still in the
    /// keychain, but under an account nothing looks at any more. Runs once —
    /// the legacy entry is removed only after the new one has been written.
    private func migrateLegacyProviderKeyIfNeeded() {
        do {
            guard let legacy = try secrets.secret(forAccount: SecretAccount.legacyLLMProviderKey),
                  !legacy.isEmpty else { return }

            let account = SecretAccount.llmProviderKey(presetID: providerSelection.presetID)
            if try secrets.secret(forAccount: account)?.isEmpty != false {
                try secrets.setSecret(legacy, forAccount: account)
            }
            try secrets.setSecret(nil, forAccount: SecretAccount.legacyLLMProviderKey)
        } catch {
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

// MARK: - Building the provider

extension SettingsStore {

    /// The provider the user selected, wired to this store's keys.
    ///
    /// Throwing rather than optional-returning: a base URL the user mistyped
    /// has to reach them as a sentence — `providerConfigurationError` shows it
    /// right next to the field that caused it — instead of leaving the session
    /// quietly without a model.
    func makeProvider() throws -> any LLMProvider {
        try ProviderFactory.make(selection: providerSelection, key: providerKeyReader())
    }

    /// Reads the selected provider's key at the moment of the request.
    ///
    /// A closure and not a string: a key typed mid-call takes effect on the
    /// next suggestion, and nothing between here and the request keeps a copy
    /// of it. It is pinned to the provider that was selected when the provider
    /// object was built, so a later switch cannot send one service another
    /// service's key.
    func providerKeyReader() -> @Sendable () async -> String? {
        let presetID = providerSelection.presetID
        return { [self] in await MainActor.run { providerKey(forPresetID: presetID) } }
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
