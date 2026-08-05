//
//  ScreenTextRecognizer.swift
//  GhostMeet
//

import CoreGraphics
import Foundation
import Vision

/// Reads the words off a screenshot with the Vision framework.
///
/// For a question about the task on screen this matters more than the picture:
/// a model shown `resu1t` where the screen says `result` answers a different
/// question, and the downscaled image it is sent is exactly where that kind of
/// mistake is made. So the text is recognised from the full-resolution
/// screenshot, before `ScreenImage` shrinks anything.
///
/// It is also the half that reaches every backend. A local server or a CLI
/// cannot take an image at all (`ProviderCapabilities.acceptsImages`), and for
/// those this is the only thing they will ever know about the screen.
nonisolated enum ScreenTextRecognizer {

    /// Upper bound on what reaches the prompt.
    ///
    /// A screen full of documentation can run to tens of thousands of
    /// characters, all of which would be paid for and none of which is the
    /// question. The head of the text is kept because that is where a task
    /// statement sits.
    static let maxCharacters = 6_000

    /// Recognition languages, in order of preference. Both, because the
    /// interview may be in either and the code on screen is English regardless.
    static let languages = ["ru-RU", "en-US"]

    /// The text of the screen, in reading order. Empty when Vision found nothing
    /// or refused — an unreadable screen is not a failure worth reporting, it is
    /// simply a screen with no text on it.
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        // `accurate` costs more than `fast` and is the only level that reads
        // code reliably; it runs beside speech recognition, where its cost is
        // hidden (see `SessionEngine.recognize`).
        request.recognitionLevel = .accurate
        // Off on purpose: language correction is built for prose and rewrites
        // identifiers — `NSURLSession` into `NS URL Session`, `argv` into `argue`.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = request.results ?? []
        let lines = observations
            .sorted(by: isAbove)
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return clipped(lines.joined(separator: "\n"))
    }

    /// Reading order: down the screen first, then left to right within a line.
    ///
    /// Vision's coordinates put the origin at the bottom left, so "higher on
    /// screen" is a larger `midY`. The tolerance is what keeps two fragments of
    /// the same line — a keyword and the rest of the statement — from being
    /// ordered by a pixel of vertical jitter.
    private static func isAbove(
        _ lhs: VNRecognizedTextObservation,
        _ rhs: VNRecognizedTextObservation
    ) -> Bool {
        let sameLine = 0.01
        let left = lhs.boundingBox
        let right = rhs.boundingBox
        if abs(left.midY - right.midY) > sameLine { return left.midY > right.midY }
        return left.minX < right.minX
    }

    private static func clipped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }
}
