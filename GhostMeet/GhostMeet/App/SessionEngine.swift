//
//  SessionEngine.swift
//  GhostMeet
//

import Foundation
import Observation
import os

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
    /// Last capture failure — of audio or of the screen — shown inside the
    /// window and nowhere else.
    private(set) var lastError: String?

    /// Segmentation thresholds. Changing them takes effect on the turns that
    /// start afterwards.
    var config: TurnSegmentationConfig {
        didSet {
            for segmenter in segmenters.values { segmenter.config = config }
        }
    }

    private let clock: SessionClock

    /// Lifecycle of capture only — which sources came up, and what stopped them.
    ///
    /// Deliberate, not debugging: the overlay is excluded from screen capture and
    /// shows no log of its own, so when a user reports "it does not hear me" the
    /// unified log is the only way to tell a capture that never started from one
    /// that started and stayed quiet. Nothing per frame and nothing anybody said
    /// is ever written here.
    @ObservationIgnored private static let log = Logger(
        subsystem: "Mixxy.GhostMeet",
        category: "capture"
    )

    private let recognizer: SpeechRecognizer
    private let sources: [AudioSource]
    /// Where the screenshot and the text on it come from.
    ///
    /// Behind a protocol for the same reason capture and speech are (ADR-0001):
    /// the engine must be drivable without a display server or a Screen
    /// Recording grant, and a test has to be able to say what the screen showed.
    private let capturer: any ScreenCapturer
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
    /// The prompts of the modes the user starts by hand — `Ask` and `Solve on
    /// screen`. Separate from `composer` because it answers a different question:
    /// that one is handed the conversation, this one is handed what the user
    /// asked for.
    private let manualComposer: any ManualComposer
    private let segmenters: [Channel: TurnSegmenter]
    private var pauseWatchdog: Timer?
    /// Recognition running per closed turn. Each task removes its own entry when
    /// it is done, so what is left here is what is genuinely still being worked
    /// on — the newest `Them` turn waits on exactly that before its request is
    /// composed.
    private var recognitionInFlight: [Turn.ID: Task<Void, Never>] = [:]
    /// The generation currently running. A newer `Them` turn cancels it, which
    /// is what stops the model answering a question that is no longer being
    /// asked (ADR-0003); it also lets whoever needs the finished suggestion wait
    /// for it.
    private var suggestionTask: Task<Void, Never>?
    /// The screenshot being taken for that generation.
    ///
    /// Held apart from the generation because it starts earlier — the instant
    /// the turn closed, beside recognition — and has to be cancellable on its
    /// own. A superseded turn otherwise pays for a frame and a few hundred
    /// milliseconds of text recognition nobody will read.
    private var screenTask: Task<ScreenContext, Never>?
    /// The `Them` turn the loop is currently answering.
    ///
    /// The single answer to "is this work still current?": recognition is never
    /// cancelled — the words belong in the transcript whatever happens — so the
    /// pipeline hanging off it has to be able to tell that a newer question
    /// arrived while it was running, and stop of its own accord.
    private var answering: Turn.ID?

    init(
        sources: [AudioSource] = [],
        recognizer: SpeechRecognizer = StubSpeechRecognizer(),
        provider: (any LLMProvider)? = nil,
        // Defaulted in the body rather than here: the composer is main-actor
        // isolated, and a default argument is evaluated outside any actor.
        composer: (any SuggestionComposer)? = nil,
        manualComposer: (any ManualComposer)? = nil,
        capturer: (any ScreenCapturer)? = nil,
        clock: SessionClock = SystemClock(),
        config: TurnSegmentationConfig = .default
    ) {
        self.sources = sources
        self.recognizer = recognizer
        self.provider = provider
        self.composer = composer ?? AssistSuggestionComposer()
        self.manualComposer = manualComposer ?? ManualPromptComposer()
        self.capturer = capturer ?? ScreenCaptureService()
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
            Self.log.error("ЗАХВАТ НЕ СТАРТОВАЛ причина=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        isListening = true
        let started = sources.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        Self.log.info("ЗАХВАТ СТАРТОВАЛ источники=\(started, privacy: .public)")
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
        if let captured = segmenter.accept(frame, at: clock.now) {
            append(captured)
        }
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
        for task in running.values { await task.value }
    }

    /// Waits for the suggestion a closed `Them` turn may have started, including
    /// the recognition that precedes it.
    ///
    /// Same reason as `waitForRecognition()`: generation runs beside the call so
    /// that nothing waits on the model, and a test has to be able to reach the
    /// end of it without sleeping.
    func waitForSuggestion() async {
        await waitForRecognition()
        // Waiting once is not enough for a request the user made by hand: that
        // one waits for the screenshot in a task of its own and only then hands
        // the slot to the task that reads the stream. Following the slot until it
        // stops changing covers both shapes with one rule.
        var awaited: Task<Void, Never>?
        while let task = suggestionTask, task != awaited {
            awaited = task
            await task.value
        }
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

        // A closed `Them` turn is the question now, and that is settled here — at
        // the instant the turn closed, before recognition has produced a single
        // word of it. Everything the previous question set going stops, and the
        // screenshot for this one starts.
        //
        // A closed `You` turn does none of it. The user is answering, and the
        // suggestion on screen is their crib sheet: it keeps growing and keeps
        // standing until the interlocutor speaks again (ADR-0003).
        let screen: Task<ScreenContext, Never>? = channel == .them
            ? startAnswering(turn: id)
            : nil

        // Everything still being recognised when this turn closed. An
        // interlocutor who paused mid-sentence leaves two turns behind, and a
        // request composed before the first of them landed would answer half a
        // question. The snapshot is taken before this turn's own task joins the
        // list, so no task can ever wait on itself.
        let earlier = Array(recognitionInFlight.values)

        let task = Task { [weak self] in
            defer { self?.recognitionInFlight[id] = nil }

            // A failed pass leaves the turn in place with no text: losing a turn
            // would be worse than showing one without words.
            let text = (try? await recognizer.transcribe(audio)) ?? ""
            // Recognition is never cancelled, not even by the turn that
            // supersedes this one: those words still belong in the transcript,
            // and the request answering the newer turn is built from them. What
            // gets cancelled is the answer, never the record of what was said.
            self?.apply(text: text, to: id)

            // The rest of the pipeline runs only for `Them`, and only while it is
            // still the current question.
            guard let screen else { return }
            for pending in earlier { await pending.value }
            guard self?.answering == id else { return }
            let context = await screen.value
            guard self?.answering == id else { return }
            self?.startSuggestion(promptedBy: id, screen: context)
        }
        recognitionInFlight[id] = task
    }

    /// Takes a newly closed `Them` turn as the question being answered, and
    /// starts the screenshot that will travel with it.
    ///
    /// The screen is grabbed beside recognition rather than after it. Two
    /// reasons, and both matter: this is the screen the question was asked about,
    /// and the proactive loop exists for speed — running it in parallel puts the
    /// screenshot and the OCR inside the time speech recognition takes instead of
    /// adding them in front of the first token.
    ///
    /// - Returns: the capture in progress, or nil when there is no provider to
    ///   answer with — the app stays usable before one is configured, and a
    ///   closed turn then simply asks for nothing.
    private func startAnswering(turn id: Turn.ID) -> Task<ScreenContext, Never>? {
        supersedeAnswerInFlight()
        answering = id
        guard provider != nil else { return nil }
        let task = Task { [capturer] in await capturer.capture() }
        screenTask = task
        return task
    }

    /// Stops everything the previous question set going.
    ///
    /// Three things at once, because all three are work on a question nobody is
    /// asking any more. The generation: cancellation reaches the socket in every
    /// provider, so a superseded request stops costing time and money instead of
    /// being counted to the end in the background. The screenshot being taken for
    /// it: a frame plus a few hundred milliseconds of text recognition that
    /// nothing will read. And the suggestion itself, which settles as
    /// `superseded`.
    ///
    /// What was already written stays on screen. The feed is history, and half an
    /// answer the user is in the middle of reading is not rubbish — it simply
    /// stops growing (ADR-0003).
    private func supersedeAnswerInFlight() {
        suggestionTask?.cancel()
        suggestionTask = nil
        screenTask?.cancel()
        screenTask = nil
        for index in suggestions.indices where !suggestions[index].isSettled {
            suggestions[index].state = .superseded
        }
    }

    private func apply(text: String, to id: Turn.ID) {
        guard !text.isEmpty, let index = transcript.firstIndex(where: { $0.id == id }) else { return }
        transcript[index].text = text
    }

    // MARK: - Ручные режимы

    /// Answers a question the user typed — mode `Ask`.
    ///
    /// Blank input does nothing at all rather than asking the model to answer
    /// nothing: an empty question would still supersede the suggestion on screen,
    /// and losing a half-read answer to a stray Return is a worse outcome than a
    /// button that seems not to have worked.
    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        startManualAnswer(.question(text))
    }

    /// Solves the task on the screen — mode `Solve on screen`.
    ///
    /// Needs no session: the screen is the whole input, so this works before
    /// listening has ever been started and keeps working after it is stopped.
    func solveOnScreen() {
        startManualAnswer(.screenTask)
    }

    /// Takes what the user asked for as the question being answered, and starts
    /// the screenshot that will travel with it.
    ///
    /// Deliberately the very same machinery as a closed `Them` turn, down to the
    /// order: supersede first, then capture, then generate. A manual request is
    /// not a side channel — it is subject to the same rule, so the next `Them`
    /// turn cancels it exactly as it cancels an automatic answer (ADR-0003).
    ///
    /// `answering` is cleared rather than set: the automatic pipeline still
    /// hanging off the last `Them` turn checks that identifier before it starts
    /// generating, so clearing it is what stops an automatic answer landing on
    /// top of the one the user just asked for. The two never run side by side —
    /// two answers streaming into one feed would leave the user reading whichever
    /// won the race.
    private func startManualAnswer(_ ask: ManualAsk) {
        guard provider != nil else {
            reportNothingToAnswerWith()
            return
        }
        supersedeAnswerInFlight()
        answering = nil

        let screen = Task { [capturer] in await capturer.capture() }
        screenTask = screen

        // The wait for the screen is the cancellable task for now; the moment
        // there is something to stream, `stream(_:from:promptedBy:screen:)`
        // takes the slot over. Either way one task is cancellable at a time,
        // which is what `supersedeAnswerInFlight()` relies on.
        suggestionTask = Task { [weak self] in
            let context = await screen.value
            guard !Task.isCancelled else { return }
            self?.startManualSuggestion(ask, screen: context)
        }
    }

    private func startManualSuggestion(_ ask: ManualAsk, screen: ScreenContext) {
        guard let provider else { return }
        let request = manualComposer.compose(
            ask,
            transcript: transcript,
            screen: screen,
            accepting: provider.capabilities
        )
        stream(request, from: provider, promptedBy: nil, screen: screen)
    }

    /// Says in the feed that there is no model to answer with.
    ///
    /// Only the manual modes report this. The automatic loop stays silent
    /// without a provider — nobody asked it for anything, and a card per closed
    /// `Them` turn would bury the window in identical complaints. A button the
    /// user pressed is the opposite case: silence there reads as a broken app.
    ///
    /// Inside the window and nowhere else, like every other failure (ADR-0004).
    private func reportNothingToAnswerWith() {
        suggestions.append(
            Suggestion(state: .failed(LLMFailure.missingKey.message), startedAt: Date())
        )
    }

    // MARK: - Suggestions

    /// Starts one generation and puts it in the feed straight away.
    ///
    /// The suggestion is appended empty and `streaming`, before a single
    /// fragment has arrived: that is what lets the window show the answer being
    /// written instead of a spinner followed by a wall of text.
    ///
    /// Reading the stream is a task of its own — the one `supersedeAnswerInFlight()`
    /// cancels — rather than a continuation of the recognition that led here. That
    /// split is the whole of ticket 08: a superseded turn must lose its answer and
    /// keep its words.
    private func startSuggestion(promptedBy turn: Turn.ID?, screen: ScreenContext) {
        guard let provider else { return }
        let request = composer.compose(
            transcript: transcript,
            screen: screen,
            accepting: provider.capabilities
        )
        stream(request, from: provider, promptedBy: turn, screen: screen)
    }

    /// Starts the generation itself, whichever mode assembled the request.
    ///
    /// The engine gets no further than this into what was asked: which prompt,
    /// how much of the conversation and how many tokens were all decided by the
    /// composer, and from here on a question the user typed and a question the
    /// interlocutor asked are the same object with the same lifecycle.
    private func stream(
        _ request: SuggestionRequest,
        from provider: any LLMProvider,
        promptedBy turn: Turn.ID?,
        screen: ScreenContext
    ) {
        // A screen that could not be grabbed is reported and then stepped over:
        // the request goes out without a picture rather than not at all
        // (ADR-0003). The reason lives in the window and nowhere else — a system
        // banner would be drawn over the shared screen (ADR-0004).
        //
        // Cleared on a capture that worked, so a one-off failure does not leave
        // a sentence on screen for the rest of the call. Nothing else writes
        // here mid-session: an audio source that fails to start throws out of
        // `start()` and there is no session to report into.
        lastError = screen.failure

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
