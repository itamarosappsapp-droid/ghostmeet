//
//  SpeechModelProvider.swift
//  GhostMeet
//

import Foundation

/// A model that is loaded and can turn samples into text.
///
/// Deliberately narrower than what the underlying engine offers: no timestamps,
/// no segments, no language handle. Everything above this line works with one
/// closed turn and the words that were said in it, which is all the transcript
/// holds (`CONTEXT.md`, «Реплика»).
nonisolated protocol SpeechModelSession: Sendable {
    /// - Parameter samples: mono PCM at `WhisperModel.requiredSampleRate`.
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Fetches model files and loads them.
///
/// Split in two on purpose: fetching is the slow, network-bound half that has to
/// report progress, loading is the local half that does not. Keeping them apart
/// is what lets the recogniser tell `.downloading` from `.loading` without the
/// backend knowing anything about how that is presented.
///
/// This is also the seam that keeps WhisperKit out of the tests: a fake provider
/// hands back a session immediately, so nothing ever reaches the network
/// (`spec.md`, Testing Decisions).
nonisolated protocol SpeechModelProvider: Sendable {
    /// Downloads the model unless it is already on disk.
    ///
    /// - Parameter onProgress: fraction of the download, `0...1`. May be called
    ///   from any thread and any number of times, including not at all when the
    ///   files are already cached.
    /// - Returns: the folder the model files ended up in.
    func fetch(
        _ model: WhisperModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    /// Loads previously fetched files into a usable session.
    func load(_ model: WhisperModel, from folder: URL) async throws -> any SpeechModelSession
}
