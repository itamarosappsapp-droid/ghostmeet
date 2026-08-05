//
//  SessionIndicators.swift
//  GhostMeet
//

import Foundation

/// What one indicator is saying.
///
/// Five states and not three, because "слушает / думает / ошибка" leaves out the
/// two the user actually spends most of a call looking at: nothing is running
/// yet, and something is on its way. Collapsing either of them into "ошибка"
/// would cry wolf; collapsing them into "выключено" would hide a model that is
/// still downloading.
nonisolated enum IndicatorState: Equatable, Sendable {
    /// Nothing is happening, and nothing is wrong.
    case idle
    /// On its way, or waiting for something the user may have to provide.
    case waiting
    /// Audio is arriving on this channel.
    case listening
    /// The model is writing.
    case thinking
    /// Broken, with a reason the user can act on.
    case failed

    /// Whether this state has to be spelled out in the window rather than left
    /// in a tooltip.
    var deservesAnExplanation: Bool {
        self == .waiting || self == .failed
    }
}

/// One dot in the header: what it stands for, what it is doing, and why.
nonisolated struct Indicator: Equatable, Sendable, Identifiable {

    /// Stable id for `ForEach` — the channel name in lowercase Latin.
    let id: String
    /// What the user sees next to the dot.
    let name: String
    let state: IndicatorState
    /// One sentence, in the user's language, saying what that state means here.
    let detail: String
}

/// The state of a call as three dots.
///
/// Two of them are the channels, which by the glossary never mix and are never
/// summarised into one number. The third is the model: the `думает` state
/// belongs to it and not to either channel, and folding it into `Them` — the
/// channel whose turn started the generation — would report a working microphone
/// feed as busy and a failed request as a broken capture.
///
/// A value type computed from the session rather than state of its own, so the
/// rules can be checked without a window, a microphone, or a model.
///
/// Main-actor isolated, unlike `Indicator` itself: the wordings it assembles —
/// `ThemCaptureStatus.message`, `SessionController.Failure.message` — belong to
/// types that are, and this only ever runs while a window is being drawn.
struct SessionIndicators: Equatable, Sendable {

    let you: Indicator
    let them: Indicator
    let model: Indicator

    var all: [Indicator] { [you, them, model] }

    static func make(
        isListening: Bool,
        failure: SessionController.Failure?,
        recognition: SpeechModelPhase,
        themStatus: ThemCaptureStatus,
        isGenerating: Bool,
        suggestionFailure: String?
    ) -> SessionIndicators {
        SessionIndicators(
            you: youIndicator(isListening: isListening, failure: failure, recognition: recognition),
            them: themIndicator(isListening: isListening, status: themStatus),
            model: modelIndicator(
                isListening: isListening,
                isGenerating: isGenerating,
                suggestionFailure: suggestionFailure
            )
        )
    }

    /// The microphone channel.
    ///
    /// A refusal outranks everything else: a denied microphone is the one state
    /// with a fix the user can carry out immediately, and it must not be hidden
    /// behind "модель готовится".
    private static func youIndicator(
        isListening: Bool,
        failure: SessionController.Failure?,
        recognition: SpeechModelPhase
    ) -> Indicator {
        if let failure {
            return Indicator(id: "you", name: "You", state: .failed, detail: failure.message)
        }
        if isListening {
            return Indicator(
                id: "you",
                name: "You",
                state: .listening,
                detail: "Микрофон слушает — ваша речь пишется в канал You."
            )
        }
        if let blocked = recognition.listeningBlockedReason {
            return Indicator(id: "you", name: "You", state: .waiting, detail: blocked)
        }
        return Indicator(
            id: "you",
            name: "You",
            state: .idle,
            detail: "Прослушивание выключено. Нажмите «Слушать» или используйте хоткей."
        )
    }

    /// The channel of everyone else, in the capture layer's own words.
    ///
    /// A broken capture is reported even while the session is stopped: it is
    /// usually a missing Screen Recording grant, and that is worth knowing
    /// *before* the call rather than during it.
    private static func themIndicator(isListening: Bool, status: ThemCaptureStatus) -> Indicator {
        if case .failed = status {
            return Indicator(id: "them", name: "Them", state: .failed, detail: status.message)
        }
        guard isListening else {
            return Indicator(
                id: "them",
                name: "Them",
                state: .idle,
                detail: "Прослушивание выключено — звук собеседника не пишется."
            )
        }
        switch status {
        case .capturing:
            return Indicator(id: "them", name: "Them", state: .listening, detail: status.message)
        case .idle, .waitingForSource:
            return Indicator(id: "them", name: "Them", state: .waiting, detail: status.message)
        case .failed:
            return Indicator(id: "them", name: "Them", state: .failed, detail: status.message)
        }
    }

    /// The model. `думает` lives here, and so does a request that came back
    /// empty — the suggestion feed shows the same reason, the dot is what makes
    /// it visible when the feed has scrolled.
    private static func modelIndicator(
        isListening: Bool,
        isGenerating: Bool,
        suggestionFailure: String?
    ) -> Indicator {
        if isGenerating {
            return Indicator(
                id: "model",
                name: "Модель",
                state: .thinking,
                detail: "Модель пишет подсказку."
            )
        }
        if let suggestionFailure {
            return Indicator(id: "model", name: "Модель", state: .failed, detail: suggestionFailure)
        }
        return Indicator(
            id: "model",
            name: "Модель",
            state: .idle,
            detail: isListening
                ? "Ждём реплику собеседника — подсказка запустится сама."
                : "Подсказка появляется сама после реплики собеседника."
        )
    }
}
