//
//  SessionController.swift
//  GhostMeet
//

import Foundation
import Observation
import os

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

    /// Whether the recognition model can transcribe right now.
    ///
    /// A closure rather than the model status itself: everything below this type
    /// sees `SpeechRecognizer` and must not learn that Whisper — or any
    /// particular download — is behind it (ADR-0001). The closure reads an
    /// `@Observable` phase in the app, which is what makes
    /// `startWhenRecognitionIsReady()` and the button's enabled state follow it
    /// without a notification of any kind.
    @ObservationIgnored private let isRecognitionReady: () -> Bool

    /// The start currently in flight, kept so that it can be waited for.
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(
        engine: SessionEngine,
        requestMicrophoneAccess: @escaping () async -> Bool = { await MicCaptureService.requestAccess() },
        isRecognitionReady: @escaping () -> Bool = { true }
    ) {
        self.engine = engine
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.isRecognitionReady = isRecognitionReady
    }

    // MARK: - What the overlay reads

    var isListening: Bool { engine.isListening }

    /// Whether pressing "Слушать" would do anything.
    ///
    /// The overlay disables the button on this and prints the reason next to it.
    /// The point is not tidiness: a turn closed before the model is loaded is
    /// refused outright rather than queued (`WhisperSpeechRecognizer`), so
    /// listening that starts a few seconds early does not merely lag — it drops
    /// the opening question of the call, in full or in half.
    var canStartListening: Bool { isRecognitionReady() }

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
    ///
    /// A model that is not ready stops the start before the microphone is even
    /// asked for — there is nothing to transcribe with, and the permission
    /// dialog would be pure noise. Nothing is recorded in `failure` for it: the
    /// reason is already on screen next to the disabled button, it is temporary
    /// by nature, and a `failure` set here would still be sitting in the window
    /// seconds later when the model has long been ready.
    func start() {
        guard !isListening, !isStarting else { return }
        guard isRecognitionReady() else { return }
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

    /// Starts listening the moment the recognition model becomes usable, and not
    /// a moment earlier.
    ///
    /// For callers that mean "listen to this call" rather than "listen now" — the
    /// autostart lever, and later the hotkey pressed while the model is still
    /// loading. Calling `start()` there would silently do nothing; this waits
    /// instead, using the same observation trick as `followThresholds(of:)`.
    func startWhenRecognitionIsReady() {
        guard !isListening, !isStarting else { return }
        let ready = withObservationTracking {
            isRecognitionReady()
        } onChange: { [weak self] in
            // `onChange` fires *before* the new value is stored, so re-reading
            // has to wait for the next turn of the main actor.
            Task { @MainActor [weak self] in
                self?.startWhenRecognitionIsReady()
            }
        }
        if ready { start() }
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
    /// `Them` follows the settings screen on its own, in both of the ways it
    /// can be re-pointed: at another application, and at the other capture
    /// backend. Neither needs the session restarted, let alone the app.
    ///
    /// The model is whichever one the settings screen selected, built through
    /// `ProviderFactory` — never a hard-wired Claude. `provider` overrides it so
    /// that a test can put a stub in the same slot; when it does, nothing should
    /// call `followProviderSelection(of:)` on the result, or the stub would be
    /// replaced by the user's choice.
    ///
    /// `isRecognitionReady` is the same kind of seam: the app passes the
    /// observable phase of the model it just built, a test passes a constant.
    /// It defaults to "ready" so that a test about providers or thresholds does
    /// not have to know that recognition has a warm-up at all.
    static func dualChannel(
        settings: SettingsStore,
        recognizer: SpeechRecognizer,
        isRecognitionReady: @escaping () -> Bool = { true },
        provider: (any LLMProvider)? = nil
    ) -> SessionController {
        // Which backend feeds `Them` decides whether the microphone may keep its
        // echo cancellation: voice processing and the Core Audio process tap
        // cannot both run (ADR-0005). ScreenCaptureKit does not build an
        // aggregate device around the output device — the suspected cause — so
        // with that backend the defence stays on. `SettingsStore` owns the rule.
        var voiceProcessing = settings.allowsVoiceProcessing

        // Temporary lever for the ADR-0005 experiment: the two backends have to
        // be measured with echo cancellation forced both ways, and the honest
        // rule above deliberately does not allow that combination. Remove with
        // `CaptureDiagnostics`.
        if let forced = ProcessInfo.processInfo.environment["GHOSTMEET_VPIO"] {
            voiceProcessing = forced == "1"
        }

        // One source for the whole life of the engine, with the real backend
        // swapped inside it. Which of the two it is stays a setting the user can
        // change mid-call: they fail on different machines, and a choice that
        // needed a relaunch would be made blind, once, and never revisited.
        let them = SwitchableThemSource(backend: settings.themCaptureBackend)
        them.followSourceSelection(of: settings)
        them.followCaptureBackend(of: settings)

        // Temporary probe for the "hears nothing" investigation: this status is
        // the only place the `Them` side says why it is quiet, and nothing
        // consumes it yet (that is ticket 10). Remove with `CaptureDiagnostics`.
        them.onStatusChange = { [weak them] status in
            let backend = them?.backend.displayName ?? "—"
            Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
                .info("КАНАЛ THEM (\(backend, privacy: .public)): \(status.message, privacy: .public)")
        }
        Logger(subsystem: "Mixxy.GhostMeet", category: "capture").info("""
            СБОРКА бэкенд=\(settings.themCaptureBackend.displayName, privacy: .public) \
            VPIO=\(voiceProcessing ? "вкл" : "выкл", privacy: .public) \
            источник=\(settings.themSourceApplicationID ?? "—", privacy: .public)
            """)

        return SessionController(
            engine: SessionEngine(
                sources: [MicCaptureService(voiceProcessing: voiceProcessing), them],
                recognizer: recognizer,
                provider: provider ?? (try? settings.makeProvider()),
                // The profile is read at request time rather than captured, so
                // editing it mid-call takes effect on the next suggestion.
                composer: AssistSuggestionComposer { settings.profile },
                config: settings.turnSegmentation
            ),
            isRecognitionReady: isRecognitionReady
        )
    }
}
