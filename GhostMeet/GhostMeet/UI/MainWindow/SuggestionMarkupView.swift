//
//  SuggestionMarkupView.swift
//  GhostMeet
//

import CoreGraphics
import SwiftUI

/// A suggestion drawn as the model meant it: lists as lists, emphasis as
/// emphasis, code in a box of its own.
///
/// It is handed the raw text and re-parses it on every fragment rather than being
/// fed blocks from outside. That is deliberate — the text grows by a token at a
/// time, and a card that only laid itself out once the answer was complete would
/// trade the one thing this app sells, the first line arriving early, for
/// typography.
struct SuggestionMarkupView: View {

    /// What the model has written so far. Half a sentence is normal input here.
    let text: String

    /// Body size for the prose. Code is drawn a point smaller — a narrow window
    /// fits about ten more characters of it that way, which is a line of code.
    var size: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SuggestionMarkup.blocks(of: text)) { block in
                view(of: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(of block: SuggestionBlock) -> some View {
        switch block.kind {
        case .paragraph:
            inline(block.text)
                .font(.system(size: size))

        case .heading:
            // One weight for all six levels: see `SuggestionBlock.Kind.heading`.
            inline(block.text)
                .font(.system(size: size, weight: .semibold))

        case .listItem(let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: size).monospacedDigit())
                    .foregroundStyle(.secondary)
                inline(block.text)
                    .font(.system(size: size))
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .code(let language, _):
            CodeBlockView(code: block.text, language: language, size: size - 1)
        }
    }

    private func inline(_ source: String) -> some View {
        Text(SuggestionMarkup.inline(source, size: size))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fenced block: monospaced, bordered, and never broken mid-line.
///
/// The overlay is about 420 points wide and a line of code is routinely wider,
/// so something has to give. Wrapping is the wrong thing to give: a wrapped line
/// of code has to be re-assembled in the reader's head at the exact moment they
/// have no time for it. The block scrolls sideways instead.
///
/// The sideways scroll is deliberately kept from fighting the feed. It bounces
/// only when the code is genuinely wider than the window, so a short fragment
/// behaves like plain text under the trackpad, and a vertical swipe over the
/// block still scrolls the feed behind it.
private struct CodeBlockView: View {

    let code: String
    let language: String
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.lowercase)
            }

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: size, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    // Ideal width, so nothing wraps and the scroll view has
                    // something wider than itself to scroll.
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            )
        }
    }
}

#Preview {
    SuggestionMarkupView(
        text: """
        Коротко: **сложность O(n log n)**, узкое место — сортировка.

        - хеш-таблица вместо `Array.contains`
        - один проход вместо двух
        1. посчитать частоты
        2. отсортировать по убыванию

        ```swift
        func topK(_ numbers: [Int], _ k: Int) -> [Int] {
            Dictionary(grouping: numbers, by: { $0 }).sorted { $0.value.count > $1.value.count }
        }
        ```

        Дальше можно сказать про `Heap`, если спрос
        """
    )
    .padding(12)
    .frame(width: 420)
}
