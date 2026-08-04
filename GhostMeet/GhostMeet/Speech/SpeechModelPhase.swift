//
//  SpeechModelPhase.swift
//  GhostMeet
//

import Foundation

/// What is happening with the recognition model right now.
///
/// The first use of a model pulls hundreds of megabytes over the network, so
/// "not ready yet" is a normal, long-lived state and not an error. It is
/// reported as its own phase so the interface can say *why* turns have no text
/// instead of showing an empty window.
///
/// Failures are surfaced through this type and shown inside the app window
/// only — a system notification banner would appear on top of a shared screen
/// and give GhostMeet away (ADR-0004).
nonisolated enum SpeechModelPhase: Equatable, Sendable {
    /// Nothing has been asked of the model yet.
    case idle
    /// Model files are coming over the network. `fraction` is `0...1`.
    case downloading(fraction: Double)
    /// Files are on disk and are being loaded into memory and specialised.
    case loading
    /// Recognition works.
    case ready
    /// The model could not be prepared. Carries a message for the window.
    case failed(String)

    /// Whether the model is on its way but not usable yet.
    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// Whether turns handed over right now would get text.
    var isReady: Bool { self == .ready }

    /// One line for the settings screen, in the user's language.
    var summary: String {
        switch self {
        case .idle:
            return "Модель ещё не загружена"
        case .downloading(let fraction):
            return "Скачивание модели — \(Int((fraction * 100).rounded()))%"
        case .loading:
            return "Подготовка модели"
        case .ready:
            return "Модель готова"
        case .failed(let reason):
            return "Модель не загрузилась: \(reason)"
        }
    }
}
