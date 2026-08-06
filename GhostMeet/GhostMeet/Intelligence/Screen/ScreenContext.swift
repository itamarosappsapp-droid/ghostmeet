//
//  ScreenContext.swift
//  GhostMeet
//

import Foundation

/// What the screen showed when the interlocutor stopped talking.
///
/// Two payloads, because they are not interchangeable. The image is what makes
/// a question about "this" answerable at all; the text is what makes the code on
/// screen exact — a downscaled screenshot is legible to a human and ambiguous to
/// a model, and an identifier read wrong is a wrong answer. The text also
/// survives where the image cannot: a text-only backend still gets it (see
/// `ProviderCapabilities.acceptsImages`).
///
/// A failure is a field rather than a thrown error on purpose: a screen that
/// could not be grabbed must not cancel the suggestion (ADR-0008). The request
/// goes out blind, and the reason is shown inside the window — never as a system
/// banner, which would be drawn over the shared screen (ADR-0004).
nonisolated struct ScreenContext: Equatable, Sendable {

    /// Downscaled PNG of the screen, or nil when there is none.
    var image: Data?

    /// What Vision read off the *full-resolution* screenshot, before downscaling.
    var text: String

    /// Why there is no image, in words meant for the user. Nil when the capture
    /// worked.
    var failure: String?

    init(image: Data? = nil, text: String = "", failure: String? = nil) {
        self.image = image
        self.text = text
        self.failure = failure
    }

    /// Nothing was captured, and nothing went wrong — the state of a request that
    /// never asked for the screen.
    static let none = ScreenContext()

    /// A capture that failed, with its reason.
    static func failed(_ reason: String) -> ScreenContext {
        ScreenContext(failure: reason)
    }

    /// Whether anything at all came back from the screen.
    var isEmpty: Bool {
        image == nil && text.isEmpty
    }
}

/// The seam the screen sits behind.
///
/// It exists for the same reason the audio and speech seams do (ADR-0001):
/// everything above — when the screen is grabbed, which part of it reaches the
/// prompt, what happens when it cannot be grabbed — has to be exercisable
/// without a display server or a Screen Recording grant.
///
/// `capture()` cannot fail: the caller has no useful response to a thrown error
/// beyond carrying on without a picture, so the failure travels inside the
/// result.
///
/// **Cancellation is part of the contract.** A press superseded by a newer one
/// cancels the capture it started, and an implementation that ignores that goes
/// on spending a frame and a few hundred milliseconds of text recognition on an
/// answer nobody is waiting for any more (ADR-0008). A cancelled capture answers
/// `.none`: nothing was captured, and nothing went wrong.
nonisolated protocol ScreenCapturer: Sendable {
    func capture() async -> ScreenContext
}

/// A capturer that never looks at the screen.
///
/// For wherever a suggestion is deliberately built without one — and for the
/// tests of everything that is not the screen, which must not need a display
/// server or a Screen Recording grant to run.
nonisolated struct NoScreenCapturer: ScreenCapturer {
    func capture() async -> ScreenContext { .none }
}
