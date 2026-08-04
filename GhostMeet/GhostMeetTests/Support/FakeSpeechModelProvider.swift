//
//  FakeSpeechModelProvider.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// A door the test opens by hand.
///
/// Lets a scenario hold a download open, look at what the interface is showing
/// while it is in flight, and only then let it finish — without a single sleep.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiting
        waiting.removeAll()
        for continuation in resuming { continuation.resume() }
    }
}

/// A recognition model that is entirely made up.
///
/// Nothing is downloaded, no CoreML is loaded and no gigabytes move: the tests
/// play out downloading, failing and succeeding through the same
/// `SpeechModelProvider` seam the real WhisperKit backend sits behind.
final class FakeSpeechModelProvider: SpeechModelProvider, @unchecked Sendable {

    /// How the download behaves.
    enum Download: Sendable {
        /// Files are already there.
        case instant
        /// Reports these fractions, then succeeds.
        case reporting([Double])
        /// Never finishes until the gate is opened.
        case held(Gate)
        /// The network, or the repo, said no.
        case failing(String)
    }

    /// Something went wrong — a refused download, a decoding pass that gave up.
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// What one turn of audio comes back as.
    typealias Transcription = @Sendable ([Float]) async throws -> String

    private let download: Download
    private let transcription: Transcription
    private let state = State()

    init(download: Download = .instant, transcription: @escaping Transcription = { _ in "" }) {
        self.download = download
        self.transcription = transcription
    }

    /// Models that were actually fetched, in order.
    var fetched: [WhisperModel] { state.fetched }

    func fetch(
        _ model: WhisperModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        state.record(model)
        switch download {
        case .instant:
            break
        case .reporting(let fractions):
            for fraction in fractions { onProgress(fraction) }
        case .held(let gate):
            onProgress(0.25)
            await gate.wait()
        case .failing(let reason):
            throw Failure(reason: reason)
        }
        return URL(fileURLWithPath: "/dev/null/\(model.variant)")
    }

    func load(_ model: WhisperModel, from folder: URL) async throws -> any SpeechModelSession {
        FakeSpeechModelSession(transcription: transcription)
    }

    /// Bookkeeping shared across the concurrent calls the provider may see.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [WhisperModel] = []

        var fetched: [WhisperModel] {
            lock.lock(); defer { lock.unlock() }
            return models
        }

        func record(_ model: WhisperModel) {
            lock.lock(); defer { lock.unlock() }
            models.append(model)
        }
    }
}

/// The loaded half of the fake: hands every turn to the closure the test gave.
private struct FakeSpeechModelSession: SpeechModelSession {
    let transcription: FakeSpeechModelProvider.Transcription

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcription(samples)
    }
}
