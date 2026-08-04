//
//  SpeechModelStatus.swift
//  GhostMeet
//

import Foundation
import Observation

/// What the interface knows and can do about the recognition model.
///
/// The recogniser is an actor and the settings screen is a SwiftUI view; this is
/// the one place where those two meet. It owns nothing of its own: the choice of
/// model lives in `SettingsStore` (so it survives a restart) and the phase lives
/// in the recogniser (so it is true even when no window is open). This type
/// mirrors the phase onto the main actor and writes the choice through.
///
/// Its `recognizer` is what the app hands to `SessionController.microphone`;
/// from there down everything sees `SpeechRecognizer` and nothing else.
@MainActor
@Observable
final class SpeechModelStatus {

    /// Shared instance over the shared settings.
    static let shared = SpeechModelStatus(store: .shared)

    /// Where preparation of the selected model has got to.
    private(set) var phase: SpeechModelPhase = .idle

    /// Selected model. Writing it persists the choice and tells the recogniser.
    var model: WhisperModel {
        get { store.speechModel }
        set {
            guard newValue != store.speechModel else { return }
            store.speechModel = newValue
            let recognizer = recognizer
            Task { await recognizer.use(newValue) }
        }
    }

    /// The recogniser to hand to `SessionEngine`. Behind `SpeechRecognizer` from
    /// the engine's point of view — the concrete type is visible here only
    /// because this is the type that drives its model.
    let recognizer: WhisperSpeechRecognizer

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(
        store: SettingsStore,
        provider: any SpeechModelProvider = WhisperKitModelProvider()
    ) {
        self.store = store
        self.recognizer = WhisperSpeechRecognizer(model: store.speechModel, provider: provider)

        let recognizer = self.recognizer
        observation = Task { [weak self] in
            for await phase in await recognizer.phaseUpdates() {
                self?.phase = phase
            }
        }
    }

    deinit {
        observation?.cancel()
    }

    /// Downloads and loads the selected model now.
    ///
    /// Nothing calls this automatically: a model is fetched either from the
    /// settings screen, deliberately, or by the first turn of a call. Starting a
    /// gigabyte-sized download because a window opened would be a surprise.
    func prepare() {
        let recognizer = recognizer
        Task { await recognizer.prepare() }
    }
}
