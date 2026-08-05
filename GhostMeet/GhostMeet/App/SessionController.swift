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

    /// The start currently in flight, kept so that it can be waited for.
    @ObservationIgnored private var startTask: Task<Void, Never>?

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

    /// The suggestion feed, oldest first. The last one is the answer to the
    /// question just asked and is the one the overlay highlights.
    var suggestions: [Suggestion] { engine.suggestions }

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
        startTask = Task { [weak self] in
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

    /// Waits for a start that has already been asked for.
    ///
    /// Permission is an asynchronous round trip through the system, so whoever
    /// needs to know how it ended — a test, later the hotkey path — has to be
    /// able to wait for it instead of sleeping. Mirrors
    /// `SessionEngine.waitForRecognition()`.
    func waitForStart() async {
        await startTask?.value
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

    // MARK: - Provider

    /// Keeps the model equal to what the settings screen shows.
    ///
    /// The same mechanism as `followThresholds(of:)`: the store is observable,
    /// so re-reading it after every change is the whole thing. Switching from
    /// Claude to a local server — or fixing a base URL — takes effect on the
    /// next suggestion, with no restart of the app and no restart of the call.
    func followProviderSelection(of settings: SettingsStore) {
        withObservationTracking {
            applyProvider(from: settings)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.followProviderSelection(of: settings)
            }
        }
    }

    /// Builds the selected provider and hands it to the engine.
    ///
    /// A selection that cannot be built — a mistyped base URL, an emptied model
    /// — leaves the previous provider in place on purpose: the user is editing a
    /// text field mid-call, and going silent after every keystroke that does not
    /// yet parse would be worse than answering with the provider that worked.
    /// The reason is not swallowed, it is shown by the settings screen through
    /// `SettingsStore.providerConfigurationError`, next to the field that caused
    /// it — never as a system banner, which would be drawn over the shared
    /// screen (ADR-0004).
    private func applyProvider(from settings: SettingsStore) {
        guard let provider = try? settings.makeProvider() else { return }
        engine.provider = provider
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

    /// The session the app actually runs: both channels in, thresholds as the
    /// user set them, recognition as the settings screen selected it.
    ///
    /// This is the one place where the concrete captures, the concrete
    /// recogniser and the concrete model meet. Everything below it sees
    /// `AudioSource`, `SpeechRecognizer` and `LLMProvider` only, so a second
    /// capture backend, a different recogniser or a local model arrives without
    /// this signature or the engine changing. `provider` is a parameter so that
    /// a test can put a stub in the same slot.
    ///
    /// `Them` follows the settings screen on its own: re-pointing the tap at
    /// another application mid-call needs no restart of the session.
    ///
    /// The model is whichever one the settings screen selected, built through
    /// `ProviderFactory` — never a hard-wired Claude. `provider` overrides it so
    /// that a test can put a stub in the same slot; when it does, nothing should
    /// call `followProviderSelection(of:)` on the result, or the stub would be
    /// replaced by the user's choice.
    static func dualChannel(
        settings: SettingsStore,
        recognizer: SpeechRecognizer,
        provider: (any LLMProvider)? = nil
    ) -> SessionController {
        let them = ProcessTapCaptureService()
        them.followSourceSelection(of: settings)

        return SessionController(
            engine: SessionEngine(
                sources: [MicCaptureService(), them],
                recognizer: recognizer,
                provider: provider ?? (try? settings.makeProvider()),
                // The profile is read at request time rather than captured, so
                // editing it mid-call takes effect on the next suggestion.
                composer: AssistSuggestionComposer { settings.profile },
                config: settings.turnSegmentation
            )
        )
    }
}
