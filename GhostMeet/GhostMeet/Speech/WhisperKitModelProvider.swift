//
//  WhisperKitModelProvider.swift
//  GhostMeet
//

import Foundation
import WhisperKit

/// The only file in the app that knows WhisperKit exists.
///
/// Everything else works through `SpeechModelProvider` / `SpeechModelSession`,
/// so the second engine promised by ADR-0002 — the native `SpeechAnalyzer` for
/// English-only calls — arrives as another type here and changes nothing above.
nonisolated struct WhisperKitModelProvider: SpeechModelProvider {

    /// Hugging Face repo the CoreML builds live in.
    private let repo: String

    init(repo: String = "argmaxinc/whisperkit-coreml") {
        self.repo = repo
    }

    func fetch(
        _ model: WhisperModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: model.variant,
            from: repo,
            progressCallback: { progress in onProgress(progress.fractionCompleted) }
        )
    }

    func load(_ model: WhisperModel, from folder: URL) async throws -> any SpeechModelSession {
        let config = WhisperKitConfig(
            model: model.variant,
            modelFolder: folder.path(percentEncoded: false),
            // `verbose: false` silences the package: a call transcript is the
            // last thing that should end up in the system log.
            verbose: false,
            // Loading straight away instead of prewarming: the load-unload-load
            // dance halves peak memory but doubles the wait, and the user is
            // already staring at a progress bar.
            prewarm: false,
            load: true,
            // The files are on disk by now — `fetch` put them there.
            download: false
        )
        return WhisperKitSession(kit: try await WhisperKit(config))
    }
}

/// One loaded Whisper model.
///
/// `WhisperKit` is a class the package does not declare `Sendable`, but its
/// `transcribe` is designed to be called concurrently — the package runs its own
/// batches that way on a single instance — so it is safe to hand to the two
/// channels at once. Hence `@unchecked`.
private final class WhisperKitSession: SpeechModelSession, @unchecked Sendable {

    private let kit: WhisperKit

    /// Decoding options, fixed for the whole app.
    ///
    /// `language: nil` together with `detectLanguage: true` is what closes the
    /// "Russian and English without touching a setting" requirement: a
    /// multilingual model detects the language of every turn on its own. Only
    /// multilingual variants are offered (`WhisperModel`), so this always holds.
    private static let options = DecodingOptions(
        verbose: false,
        task: .transcribe,
        language: nil,
        usePrefillPrompt: true,
        detectLanguage: true,
        skipSpecialTokens: true,
        // A turn is seconds long, well inside one Whisper window, and the
        // transcript stores the turn's own timing — timestamps would be noise.
        withoutTimestamps: true,
        wordTimestamps: false
    )

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options)
        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
