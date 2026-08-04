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
    private let segmenters: [Channel: TurnSegmenter]
    private var pauseWatchdog: Timer?
    private var recognitionInFlight: [Task<Void, Never>] = []

    init(
        sources: [AudioSource] = [],
        recognizer: SpeechRecognizer = StubSpeechRecognizer(),
        clock: SessionClock = SystemClock(),
        config: TurnSegmentationConfig = .default
    ) {
        self.sources = sources
        self.recognizer = recognizer
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

    private func append(_ captured: CapturedTurn) {
        let turn = Turn(
            channel: captured.channel,
            timestamp: captured.startedAt,
            duration: captured.duration
        )
        transcript.append(turn)
        recognize(
            turn: turn.id,
            audio: SpeechAudio(samples: captured.samples, sampleRate: captured.sampleRate)
        )
    }

    private func recognize(turn id: Turn.ID, audio: SpeechAudio) {
        let recognizer = recognizer
        let task = Task { [weak self] in
            let text = (try? await recognizer.transcribe(audio)) ?? ""
            guard !Task.isCancelled else { return }
            // A failed pass leaves the turn in place with no text: losing a turn
            // would be worse than showing one without words.
            self?.apply(text: text, to: id)
        }
        recognitionInFlight.append(task)
    }

    private func apply(text: String, to id: Turn.ID) {
        guard !text.isEmpty, let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
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
