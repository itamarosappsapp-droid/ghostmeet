//
//  SuggestionFeedView.swift
//  GhostMeet
//

import SwiftUI

/// The feed of suggestions, oldest first.
///
/// The newest one is the answer to the question just asked, so the feed scrolls
/// to it and marks it out: during a call there is no time to look for it. Older
/// ones stay readable but recede, which is what makes the feed a history the
/// user can scroll back through rather than a single replaced answer.
///
/// A suggestion that could not be produced is shown here as a card like any
/// other. This window is the only place a failure is ever reported — a system
/// banner would be drawn over the shared screen and give the app away (ADR-0004).
struct SuggestionFeedView: View {
    let suggestions: [Suggestion]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        SuggestionCard(
                            suggestion: suggestion,
                            isLatest: suggestion.id == suggestions.last?.id
                        )
                        .id(suggestion.id)
                    }
                    // Anchor at the very bottom: scrolling to the card itself
                    // stops short while the card is still growing.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .overlay {
                if suggestions.isEmpty { emptyState }
            }
            // A new suggestion is worth an animation; the fragments that follow
            // are not — animating every one of them would make the text jitter
            // while it is being read.
            .onChange(of: suggestions.last?.id) {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: suggestions.last?.text.count ?? 0) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "suggestion-feed-bottom"

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Подсказок пока нет")
                .font(.callout)
            Text("Появятся сами, как только собеседник договорит.")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
}

/// One suggestion: what the model wrote, and where it got to.
private struct SuggestionCard: View {
    let suggestion: Suggestion

    /// The newest card, the one the user is meant to be reading right now.
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background)
        .overlay(border)
        .opacity(isLatest ? 1 : 0.65)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer(minLength: 0)
        }
    }

    private var statusTitle: String {
        switch suggestion.state {
        case .streaming: "печатается"
        case .complete: "подсказка"
        case .superseded: "устарела"
        case .failed: "не получилось"
        }
    }

    private var statusColor: Color {
        switch suggestion.state {
        case .streaming: .accentColor
        case .complete: isLatest ? .accentColor : .secondary
        case .superseded: .secondary
        case .failed: .orange
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch suggestion.state {
        case .failed(let message):
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 11))
            .foregroundStyle(.orange)

        default:
            if suggestion.text.isEmpty {
                Text("…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                Text(suggestion.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Chrome

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isLatest ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isLatest ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                lineWidth: 1
            )
    }
}

#Preview {
    SuggestionFeedView(suggestions: [
        Suggestion(
            text: "Я вёл миграцию сервиса на Swift Concurrency: убрал GCD-очереди, вынес состояние в акторы.",
            state: .complete,
            startedAt: Date()
        ),
        Suggestion(state: .failed(LLMFailure.missingKey.message), startedAt: Date()),
        Suggestion(text: "Начну с оценки сложности: сейчас это O(n²), потому", startedAt: Date()),
    ])
    .frame(width: 420, height: 320)
}
