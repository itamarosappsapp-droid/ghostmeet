//
//  ProviderCatalog.swift
//  GhostMeet
//

import Foundation

/// How a provider is talked to. Three shapes cover the whole catalogue, which is
/// the point: most of the named providers are not separate implementations, they
/// are one OpenAI-compatible client pointed at a different base URL.
nonisolated enum ProviderTransport: String, Codable, CaseIterable, Sendable {
    /// Anthropic's own Messages API.
    case anthropic
    /// Anything speaking OpenAI's chat-completions dialect: OpenAI itself,
    /// OpenRouter, DeepSeek, Kimi, Polza.AI, and every local server worth using
    /// — Ollama, LM Studio, llama.cpp.
    case openAICompatible
    /// Google's `generateContent`, which is its own shape.
    case gemini
    /// A command-line tool: prompt in, answer on stdout. Rides whatever
    /// subscription the tool is already logged into, so it spends no API money.
    case cli
}

/// What a provider can actually accept.
///
/// This exists because of one hard fact: every press attaches a
/// screenshot to **every** request (ADR-0008), and most local models and every
/// CLI cannot take an image. Sending one anyway is not a degraded answer, it is
/// a failed request. So the provider declares what it accepts and the layer
/// building the request drops what it cannot use.
nonisolated struct ProviderCapabilities: Equatable, Sendable {

    /// Whether an image may be attached to the user message. When false, `Solve
    /// on screen` degrades to reasoning over OCR text alone, and the settings
    /// screen should say so rather than let the user wonder.
    var acceptsImages: Bool

    /// Whether the answer arrives in fragments. A provider that cannot stream
    /// still works — it yields one fragment — but the suggestion appears all at
    /// once, which costs the user the head start the overlay exists to give.
    var streams: Bool

    static let textOnly = ProviderCapabilities(acceptsImages: false, streams: true)
    static let multimodal = ProviderCapabilities(acceptsImages: true, streams: true)
}

/// A provider the user can pick, with everything needed to reach it.
///
/// Presets are a convenience, not a constraint: base URL and model stay
/// editable, so a provider nobody thought of is reachable by pointing the
/// OpenAI-compatible transport at it. That is what keeps "и др." from becoming a
/// code change every time.
nonisolated struct ProviderPreset: Identifiable, Equatable, Sendable {

    /// Stable identifier. Doubles as the Keychain account name, which is what
    /// lets several providers keep their keys side by side.
    let id: String

    /// Shown in the settings picker.
    let name: String

    let transport: ProviderTransport

    /// Where to send requests. Empty for `cli`.
    let defaultBaseURL: String

    /// Model identifier in that provider's own naming.
    let defaultModel: String

    /// Whether a key is required. False for local servers and for CLI tools,
    /// which authenticate themselves.
    let needsKey: Bool

    let capabilities: ProviderCapabilities

    /// For `cli`: the executable and its arguments. Empty otherwise.
    var command: [String] = []
}

/// What the user chose, and the overrides they typed. This is what gets
/// persisted; the secret never travels with it.
nonisolated struct ProviderSelection: Codable, Equatable, Sendable {

    /// `ProviderPreset.id` of the chosen provider.
    var presetID: String

    /// Overrides the preset's base URL when non-empty — the whole point of
    /// supporting a provider we have never heard of.
    var baseURL: String

    /// Overrides the preset's model when non-empty.
    var model: String

    /// Overrides a `cli` preset's command when non-empty, as a plain command
    /// line: `/opt/homebrew/bin/claude -p`.
    ///
    /// Needed because a CLI tool may live somewhere the app cannot find — an app
    /// launched from Finder inherits launchd's thin `PATH`, not the shell's — or
    /// may need an extra flag. Without this the advice "give the full path"
    /// would have nowhere to be typed.
    var commandOverride: String

    init(presetID: String, baseURL: String = "", model: String = "", commandOverride: String = "") {
        self.presetID = presetID
        self.baseURL = baseURL
        self.model = model
        self.commandOverride = commandOverride
    }

    /// Decoded field by field with fallbacks: a preferences file written by an
    /// older build is missing whatever was added since, and losing the whole
    /// selection over one absent key would silently reset the user's provider.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID) ?? "anthropic"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        commandOverride = try container.decodeIfPresent(String.self, forKey: .commandOverride) ?? ""
    }

    /// Splits the override into executable and arguments. Quoting is not
    /// supported on purpose: a path with spaces is rarer than the confusion a
    /// half-implemented shell parser would cause.
    var commandComponents: [String] {
        commandOverride.split(separator: " ").map(String.init)
    }
}
