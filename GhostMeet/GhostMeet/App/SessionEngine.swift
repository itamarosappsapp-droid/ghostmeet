//
//  SessionEngine.swift
//  GhostMeet
//

import Foundation
import Observation

/// The one orchestrator of a call.
///
/// It takes in frames of both channels, closes turns, keeps the transcript and
/// later drives suggestions. Everything outside of it is seen through protocols
/// only — `AudioSource`, `SpeechRecognizer` — so the engine never learns whether
/// audio comes from the microphone or from a process tap, nor which engine
/// recognises it (ADR-0001).
///
/// Time comes from an injected clock, which makes the engine the single seam of
/// the app: a test feeds frames, moves the clock and checks which turns showed
/// up in the transcript, without waiting in real time.
@MainActor
@Observable
final class SessionEngine {
    /// Turns of both channels in the order they were closed — the only
    /// representation of the conversation.
    private(set) var transcript: [Turn] = []
    /// Suggestions in the order they were started, oldest first — the feed the
    /// overlay shows. A suggestion appears here the moment generation starts and
    /// grows fragment by fragment, so the user starts reading before the model
    /// has finished writing.
    private(set) var suggestions: [Suggestion] = []
    /// Whether capture is running.
    private(set) var isListening = false
    /// Last capture failure, shown inside the window and nowhere else.
    private(set) var lastError: String?

    /// Segmentation thresholds. Changing them takes effect on the turns that
    /// start afterwards.
    var config: TurnSegmentationConfig {
        didSet {
            for segmenter in segmenters.values { segmenter.config = config }
        }
    }

    private let clock: SessionClock
    private let recognizer: SpeechRecognizer
    private let sources: [AudioSource]
    /// The model behind the suggestions. Optional because the app has to be
    /// usable — capture, transcript, settings — before a provider is configured;
    /// with none, a closed `Them` turn simply asks for nothing.
    ///
    /// Settable for the same reason `config` is: picking another provider in
    /// settings has to take effect on the next suggestion, not at the next
    /// launch. It is read when a generation starts, so a swap never disturbs the
    /// one already streaming. `SessionController.followProviderSelection(of:)`
    /// is what keeps it equal to the settings screen.
    @ObservationIgnored var provider: (any LLMProvider)?
    private let composer: any SuggestionComposer
    private let segmenters: [Channel: TurnSegmenter]
    private var pauseWatchdog: Timer?
    private var recognitionInFlight: [Task<Void, Never>] = []
    /// The generation currently running. Ticket 08 cancels it when a newer
    /// `Them` turn arrives; here it exists so that whoever needs the finished
    /// suggestion can wait for it.
    private var suggestionTask: Task<Void, Never>?

    init(
        sources: [AudioSource] = [],
        recognizer: SpeechRecognizer = StubSpeechRecognizer(),
        provider: (any LLMProvider)? = nil,
        // Defaulted in the body rather than here: the composer is main-actor
        // isolated, and a default argument is evaluated outside any actor.
        composer: (any SuggestionComposer)? = nil,
        clock: SessionClock = SystemClock(),
        config: TurnSegmentationConfig = .default
    ) {
        self.sources = sources
        self.recognizer = recognizer
        self.provider = provider
        self.composer = composer ?? AssistSuggestionComposer()
        self.clock = clock
        self.config = config
        self.segmenters = Dictionary(
            uniqueKeysWithValues: Channel.allCases.map { channel in
                (channel, TurnSegmenter(channel: channel, config: config))
            }
        )
    }

    /// Starts listening on every configured source.
    func start() throws {
        guard !isListening else { return }
        lastError = nil
        do {
            for source in sources {
                try source.start { [weak self] frame in
                    // Frames arrive on a realtime audio thread; the transcript
                    // lives on the main actor, so the hop happens here, in the
                    // one place that knows about both.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.ingest(frame) }
                    }
                }
            }
        } catch {
            sources.forEach { $0.stop() }
            lastError = error.localizedDescription
            throw error
        }
        isListening = true
        startPauseWatchdog()
    }

    /// Stops listening and closes the turn that was in progress.
    func stop() {
        guard isListening else { return }
        sources.forEach { $0.stop() }
        pauseWatchdog?.invalidate()
        pauseWatchdog = nil
        isListening = false
        for channel in Channel.allCases {
            if let captured = segmenters[channel]?.flush() { append(captured) }
        }
    }

    /// Takes one captured frame.
    ///
    /// The channel comes from the frame, that is from the source that produced
    /// it, and never from what was said.
    func ingest(_ frame: AudioFrame) {
        guard let segmenter = segmenters[frame.channel] else { return }
        if let captured = segmenter.accept(frame, at: clock.now) { append(captured) }
    }

    /// Lets time pass without new audio: a turn still closes on its pause or on
    /// the forced flush even if the source went quiet altogether.
    func tick() {
        let now = clock.now
        for channel in Channel.allCases {
            if let captured = segmenters[channel]?.evaluate(at: now) { append(captured) }
        }
    }

    /// Waits for the recognition already started for closed turns.
    ///
    /// Recognition runs beside segmentation so that a slow pass never delays the
    /// next turn; whoever needs its result has to be able to wait for it without
    /// sleeping.
    func waitForRecognition() async {
        let running = recognitionInFlight
        recognitionInFlight.removeAll()
        for task in running { await task.value }
    }

    /// Waits for the suggestion a closed `Them` turn may have started, including
    /// the recognition that precedes it.
    ///
    /// Same reason as `waitForRecognition()`: generation runs beside the call so
    /// that nothing waits on the model, and a test has to be able to reach the
    /// end of it without sleeping.
    func waitForSuggestion() async {
        await waitForRecognition()
        await suggestionTask?.value
    }

    private func append(_ captured: CapturedTurn) {
        let turn = Turn(
            channel: captured.channel,
            timestamp: captured.startedAt,
            duration: captured.duration
        )
        transcript.append(turn)
        recognize(
            turn: turn.id,
            on: turn.channel,
            audio: SpeechAudio(samples: captured.samples, sampleRate: captured.sampleRate)
        )
    }

    private func recognize(turn id: Turn.ID, on channel: Channel, audio: SpeechAudio) {
        let recognizer = recognizer
        let task = Task { [weak self] in
            let text = (try? await recognizer.transcribe(audio)) ?? ""
            guard !Task.isCancelled else { return }
            // A failed pass leaves the turn in place with no text: losing a turn
            // would be worse than showing one without words.
            self?.apply(text: text, to: id)
            // The rest of the pipeline runs from here, and only for `Them`: the
            // interlocutor stopped talking, so a suggestion is asked for on its
            // own, with the words of that very turn already in the transcript.
            // A closed `You` turn asks for nothing — the user is answering, and
            // whatever is on screen is their crib sheet (ADR-0003).
            if channel == .them { self?.startSuggestion(promptedBy: id) }
        }
        recognitionInFlight.append(task)
    }

    private func apply(text: String, to id: Turn.ID) {
        guard !text.isEmpty, let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
    }

    // MARK: - Suggestions

    /// Starts one generation and puts it in the feed straight away.
    ///
    /// The suggestion is appended empty and `streaming`, before a single
    /// fragment has arrived: that is what lets the window show the answer being
    /// written instead of a spinner followed by a wall of text.
    private func startSuggestion(promptedBy turn: Turn.ID?) {
        guard let provider else { return }

        let request = composer.compose(transcript: transcript)
        let suggestion = Suggestion(promptedBy: turn, startedAt: Date())
        suggestions.append(suggestion)

        // The request leaves before the task that reads it is scheduled: this is
        // the moment the interlocutor stopped talking, and every hop between
        // here and the first token is latency the user waits through.
        let stream = provider.stream(request)

        let id = suggestion.id
        suggestionTask = Task { [weak self] in
            do {
                for try await fragment in stream {
                    guard !Task.isCancelled else { return }
                    self?.append(fragment: fragment, to: id)
                }
                guard !Task.isCancelled else { return }
                self?.settle(id, as: .complete)
            } catch is CancellationError {
                // Superseded by a newer turn; whoever cancelled owns the state.
                return
            } catch {
                // Reported in the feed and nowhere else. A system notification
                // would be drawn over the shared screen (ADR-0004).
                self?.settle(id, as: .failed(Self.message(for: error)))
            }
        }
    }

    private func append(fragment: String, to id: Suggestion.ID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }),
              !suggestions[index].isSettled
        else { return }
        suggestions[index].text += fragment
    }

    /// Settles a suggestion, unless something already settled it: a stream that
    /// finishes after being superseded must not claim it completed.
    private func settle(_ id: Suggestion.ID, as state: Suggestion.State) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }),
              !suggestions[index].isSettled
        else { return }
        suggestions[index].state = state
    }

    /// The failure in words meant for the user: the provider's own wording when
    /// it gave one, the system's otherwise.
    private static func message(for error: any Error) -> String {
        (error as? LLMFailure)?.message ?? error.localizedDescription
    }

    private func startPauseWatchdog() {
        pauseWatchdog = Timer.scheduledTimer(
            withTimeInterval: config.pauseCheckInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
}

extension SessionEngine {
    /// Engine for the `You` channel alone: microphone in, recognition stubbed.
    ///
    /// `Them` joins later as a second source behind the same protocol, without
    /// the engine changing.
    static func microphoneOnly(config: TurnSegmentationConfig = .default) -> SessionEngine {
        SessionEngine(
            sources: [MicCaptureService()],
            recognizer: StubSpeechRecognizer(),
            config: config
        )
    }
}
