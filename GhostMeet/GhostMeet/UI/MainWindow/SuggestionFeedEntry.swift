//
//  SuggestionFeedEntry.swift
//  GhostMeet
//

import Foundation

/// One card in the feed — which is not the same thing as one `Подсказка`.
///
/// The two differ in exactly one case: a failure that keeps happening for the
/// same reason. A missing key, a provider that cannot be reached, a command that
/// is not installed — none of them get better between two presses, so pressing
/// three times writes the same sentence three times and pushes whatever the user
/// was reading off the top of the window. The failure is worth stating; stating
/// it again is not.
///
/// The collapsing lives here, in the layer that draws, and not in `SessionEngine`.
/// The engine records what happened — three presses, three failures — and that
/// record is the truth; how many cards it is worth is a question about a window
/// 420 points wide.
nonisolated struct SuggestionFeedEntry: Identifiable, Equatable, Sendable {

    /// The most recent suggestion of the run. The newest one and not the first,
    /// so the card sits where the user is looking after their last press.
    let suggestion: Suggestion

    /// How many identical failures this card stands for. `1` for everything else,
    /// which is everything the user normally sees.
    let repeats: Int

    var id: Suggestion.ID { suggestion.id }

    /// Whether this card says «and again, and again».
    var isRepeated: Bool { repeats > 1 }

    /// Folds a run of identical failures into one card.
    ///
    /// Two conditions, both load-bearing:
    ///
    /// - **Consecutive.** Anything in between — an answer that worked — means the
    ///   situation changed, and the failure after it is news again.
    /// - **Empty.** A generation that failed halfway leaves text the user may be
    ///   in the middle of reading, and that text is the whole reason the feed is a
    ///   history rather than a single replaced answer. Only failures that produced
    ///   nothing at all are folded together.
    static func feed(of suggestions: [Suggestion]) -> [SuggestionFeedEntry] {
        var entries: [SuggestionFeedEntry] = []
        for suggestion in suggestions {
            if let last = entries.last, repeats(last.suggestion, as: suggestion) {
                entries[entries.count - 1] = SuggestionFeedEntry(
                    suggestion: suggestion,
                    repeats: last.repeats + 1
                )
            } else {
                entries.append(SuggestionFeedEntry(suggestion: suggestion, repeats: 1))
            }
        }
        return entries
    }

    private static func repeats(_ previous: Suggestion, as current: Suggestion) -> Bool {
        guard case .failed(let earlier) = previous.state,
              case .failed(let reason) = current.state
        else { return false }
        return earlier == reason && previous.text.isEmpty && current.text.isEmpty
    }
}
