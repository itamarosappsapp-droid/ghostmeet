//
//  SessionController.swift
//  GhostMeet
//

import Foundation
import Observation

/// Everything that stands between the button in the overlay and `SessionEngine`.
///
/// The engine sees its sources through `AudioSource` and must not learn what
/// they are; asking the operating system for permission, on the other hand, is
/// source-specific — the microphone has its own gate, `Them` will bring another
/// one (screen recording). So the gate lives here, one level above the engine.
///
/// A refusal is kept as state and shown inside the overlay window. It must never
/// become a system notification: the banner would be drawn on top of whatever
/// the user is sharing and hand the app over (ADR-0004).
@Observable
final class SessionController {

    /// Why listening is not running, in words meant for the user. `nil` while
    /// nothing has gone wrong.
    private(set) var failure: Failure?

    /// A start is in flight — the system permission dialog may be up.
    private(set) var isStarting = false

    /// The engine itself, exposed so that later screens (suggestion feed,
    /// context clearing) can reach it without going through this type.
    let engine: SessionEngine

    /// The microphone gate, injected so the seam is testable and so this type
    /// keeps no direct knowledge of `AVFoundation`.
    @ObservationIgnored private let requestMicrophoneAccess: () async -> Bool

    init(
        engine: SessionEngine,
        requestMicrophoneAccess: @escaping () async -> Bool = { await MicCaptureService.requestAccess() }
    ) {
        self.engine = engine
        self.requestMicrophoneAccess = requestMicrophoneAccess
    }

    // MARK: - What the overlay reads

    var isListening: Bool { engine.isListening }

    /// The transcript as it stands: turns of both channels in the order they
    /// were closed.
    var transcript: [Turn] { engine.transcript }

    // MARK: - Start and stop

    func toggle() {
        isListening ? stop() : start()
    }

    /// Asks for microphone access and starts capture once it is granted.
    ///
    /// Access is requested every time rather than once at launch: a user who
    /// declined can grant it in System Settings and press the button again
    /// without restarting the app.
    func start() {
        guard !isListening, !isStarting else { return }
        failure = nil
        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            let granted = await requestMicrophoneAccess()
            isStarting = false
            guard granted else {
                failure = .microphoneDenied
                return
            }
            do {
                try engine.start()
            } catch {
                failure = .captureFailed(error.localizedDescription)
            }
        }
    }

    /// Stops capture and closes the turn that was in progress.
    func stop() {
        engine.stop()
    }

    // MARK: - Thresholds

    /// Keeps the engine's thresholds equal to what the settings screen shows.
    ///
    /// The store is observable, so re-reading it after every change is the whole
    /// mechanism: no notification, no restart of the session, no Apply button.
    /// Only turns that start afterwards are affected, which is what the engine
    /// documents.
    func followThresholds(of settings: SettingsStore) {
        withObservationTracking {
            engine.config = settings.turnSegmentation
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.followThresholds(of: settings)
            }
        }
    }
}

extension SessionController {

    /// Why the session is not listening.
    ///
    /// Two cases, because the user's next step differs: a denied microphone is
    /// fixed in System Settings, a capture failure is not.
    enum Failure: Equatable {
        /// The system refused microphone access, or the user did.
        case microphoneDenied
        /// Capture itself failed to start — VPIO unavailable, no input format.
        case captureFailed(String)

        var message: String {
            switch self {
            case .microphoneDenied:
                "Нет доступа к микрофону. Разрешите его в «Системных настройках» → «Конфиденциальность и безопасность» → «Микрофон», затем нажмите «Слушать» ещё раз."
            case .captureFailed(let reason):
                reason
            }
        }

        /// Whether the user can be sent straight to the switch that fixes it.
        var isPermissionDenied: Bool { self == .microphoneDenied }
    }

    /// The session the app actually runs: microphone in, thresholds as the user
    /// set them, recognition as the settings screen selected it.
    ///
    /// This is the one place where the concrete capture and the concrete
    /// recogniser meet. Everything below it sees `AudioSource` and
    /// `SpeechRecognizer` only, so `Them` joins later as a second source and a
    /// different engine as a different recogniser, without this signature or the
    /// engine changing.
    static func microphone(
        settings: SettingsStore,
        recognizer: SpeechRecognizer
    ) -> SessionController {
        SessionController(
            engine: SessionEngine(
                sources: [MicCaptureService()],
                recognizer: recognizer,
                config: settings.turnSegmentation
            )
        )
    }
}
