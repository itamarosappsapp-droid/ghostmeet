//
//  SuggestionCardTests.swift
//  GhostMeetTests
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import GhostMeet

// MARK: - Helpers

/// What the user actually reads in a block, with every delimiter resolved — the
/// same path the card takes.
private func rendered(_ block: SuggestionBlock) -> String {
    String(SuggestionMarkup.inline(block.text, size: 13).characters)
}

/// Everything the card would draw as prose, joined. Code blocks are left out:
/// they are verbatim by design, and backticks inside them are the code's own.
private func renderedProse(_ source: String) -> String {
    SuggestionMarkup.blocks(of: source)
        .filter { !$0.isCode }
        .map(rendered)
        .joined(separator: "\n")
}

/// A reference answer of the shape a technical interview produces: emphasis,
/// both kinds of list, inline code, a fenced block, and an arithmetic asterisk
/// that is not markup at all.
private let technicalAnswer = """
Коротко: **O(n log n)**, узкое место — сортировка.

- заменить `Array.contains` на `Set`
- один проход вместо двух

1. посчитать частоты
2. отсортировать по убыванию

```swift
func topK(_ numbers: [Int], _ k: Int) -> [Int] {
    Array(counts.sorted { $0.value > $1.value }.prefix(k).map(\\.key))
}
```

Итого примерно n * log n операций, память O(n).
"""

// MARK: - Разбор

@Suite("Разметка подсказки разбирается")
struct SuggestionMarkupParsingTests {

    @Test("Маркеры списка становятся пунктами, а из текста исчезают")
    func listMarkersBecomeBullets() {
        let blocks = SuggestionMarkup.blocks(of: "- первое\n- второе")
        #expect(blocks.count == 2)
        #expect(blocks.allSatisfy { $0.kind == .listItem(marker: "•", indent: 0) })
        #expect(blocks.map(\.text) == ["первое", "второе"])
    }

    @Test("Нумерованный список сохраняет свои номера")
    func numberedItemsKeepTheirNumbers() {
        let blocks = SuggestionMarkup.blocks(of: "1. раз\n2. два\n10) десять")
        #expect(blocks.map(\.kind) == [
            .listItem(marker: "1.", indent: 0),
            .listItem(marker: "2.", indent: 0),
            .listItem(marker: "10.", indent: 0),
        ])
        #expect(blocks.map(\.text) == ["раз", "два", "десять"])
    }

    @Test("Вложенный пункт помнит свой уровень")
    func anIndentedItemKeepsItsLevel() {
        let blocks = SuggestionMarkup.blocks(of: "- верхний\n  - вложенный")
        #expect(blocks.last?.kind == .listItem(marker: "•", indent: 1))
    }

    @Test("Жирный текст и инлайн-код доезжают до карточки без своих символов")
    func inlineMarkupLosesItsPunctuation() {
        let blocks = SuggestionMarkup.blocks(of: "Это **важно**, вызовите `flush()` сами.")
        #expect(blocks.count == 1)
        #expect(rendered(blocks[0]) == "Это важно, вызовите flush() сами.")

        let attributed = SuggestionMarkup.inline(blocks[0].text, size: 13)
        let strong = attributed.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        let code = attributed.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(strong, "жирный текст обязан остаться жирным, а не просто потерять звёздочки")
        #expect(code, "инлайн-код обязан быть размечен — иначе он неотличим от прозы")
    }

    @Test("Инлайн-код рисуется моноширинным: ради этого всё и затевалось")
    func inlineCodeIsMonospaced() {
        let attributed = SuggestionMarkup.inline("вызовите `flush()`", size: 13)
        let code = attributed.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(code?.font == .system(size: 13, design: .monospaced))
    }

    @Test("Заголовок остаётся строкой текста, решётки не показываются")
    func aHeadingKeepsItsWordsAndLosesItsHashes() {
        let blocks = SuggestionMarkup.blocks(of: "## Что сказать\nдальше текст")
        #expect(blocks.first?.kind == .heading(level: 2))
        #expect(blocks.first?.text == "Что сказать")
        #expect(blocks.last?.kind == .paragraph)
    }

    @Test("Блок кода отделён от текста и внутри не размечается")
    func aFencedBlockIsKeptVerbatim() {
        let blocks = SuggestionMarkup.blocks(of: technicalAnswer)
        let code = blocks.filter(\.isCode)
        #expect(code.count == 1)
        #expect(code[0].kind == .code(language: "swift", isClosed: true))
        #expect(code[0].text.hasPrefix("func topK"))
        #expect(code[0].text.contains("\n"), "блок кода обязан остаться многострочным")
        #expect(!code[0].text.contains("```"), "ограда — не часть кода")
    }

    @Test("Звёздочка умножения остаётся звёздочкой, а не курсивом")
    func multiplicationIsNotEmphasis() {
        #expect(SuggestionMarkup.balanced("примерно n * log n операций") == "примерно n * log n операций")
        #expect(renderedProse("сложность n * log n").contains("n * log n"))
    }

    @Test("Пустая строка разделяет абзацы, а соседние строки — нет")
    func blankLinesSeparateParagraphs() {
        let blocks = SuggestionMarkup.blocks(of: "первый\nвторой\n\nтретий")
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "первый\nвторой")
        #expect(blocks[1].text == "третий")
    }

    @Test("Пустой ответ не даёт ни одного блока")
    func nothingWrittenDrawsNothing() {
        #expect(SuggestionMarkup.blocks(of: "").isEmpty)
        #expect(SuggestionMarkup.blocks(of: "\n\n   \n").isEmpty)
    }

    @Test("Идентификаторы блоков идут подряд — по ним ForEach и различает карточки")
    func blocksAreIdentifiedByPosition() {
        let blocks = SuggestionMarkup.blocks(of: technicalAnswer)
        #expect(blocks.map(\.id) == Array(blocks.indices))
    }
}

// MARK: - Потоковый вывод

@Suite("Разметка переживает потоковый вывод")
struct SuggestionMarkupStreamingTests {

    /// Every prefix of the answer, which is exactly what the card is handed while
    /// the model writes.
    private func prefixes(of source: String) -> [String] {
        (1...source.count).map { String(source.prefix($0)) }
    }

    @Test("Ни на одном шаге потока в тексте не видно символов разметки")
    func noPrefixEverShowsItsDelimiters() {
        for prefix in prefixes(of: technicalAnswer) {
            let prose = renderedProse(prefix)
            #expect(!prose.contains("**"), "звёздочки видны на «…\(prefix.suffix(24))»")
            #expect(!prose.contains("`"), "обратные кавычки видны на «…\(prefix.suffix(24))»")
            #expect(!prose.contains("###"), "решётки видны на «…\(prefix.suffix(24))»")
        }
    }

    @Test("Незакрытая ограда уже показывается блоком кода, а не строкой с кавычками")
    func anUnclosedFenceIsAlreadyACodeBlock() {
        let half = "Решение:\n```swift\nfunc topK("
        let blocks = SuggestionMarkup.blocks(of: half)
        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .code(language: "swift", isClosed: false))
        #expect(blocks[1].text == "func topK(")
    }

    @Test("Блок кода растёт по строкам, а не появляется целиком в конце")
    func aCodeBlockGrowsLineByLine() {
        let source = "```swift\nlet a = 1\nlet b = 2\n```"
        let seen = prefixes(of: source)
            .compactMap { SuggestionMarkup.blocks(of: $0).first(where: \.isCode)?.text }
        #expect(seen.contains("let a = 1"), "первая строка обязана показаться до прихода второй")
        #expect(seen.contains("let a = 1\nlet b = 2"))
        #expect(seen.last == "let a = 1\nlet b = 2")
    }

    @Test("Закрытие ограды не меняет того, что уже прочитано")
    func closingTheFenceChangesNothingVisible() {
        let open = SuggestionMarkup.blocks(of: "```swift\nlet a = 1\n")
        let closed = SuggestionMarkup.blocks(of: "```swift\nlet a = 1\n```")
        #expect(open.map(\.text) == closed.map(\.text))
        #expect(open.last?.kind == .code(language: "swift", isClosed: false))
        #expect(closed.last?.kind == .code(language: "swift", isClosed: true))
    }

    @Test("Недописанное выделение уже выделено, а не показано звёздочками")
    func ahalfWrittenEmphasisIsAlreadyEmphasis() {
        #expect(SuggestionMarkup.balanced("это **важ") == "это **важ**")
        #expect(SuggestionMarkup.balanced("вызовите `flush") == "вызовите `flush`")
        #expect(rendered(SuggestionMarkup.blocks(of: "это **важ")[0]) == "это важ")
    }

    @Test("Только что набранный маркер не показывается вовсе")
    func adelimiterBeingTypedIsHidden() {
        #expect(SuggestionMarkup.balanced("это **") == "это ")
        #expect(SuggestionMarkup.balanced("вызовите `") == "вызовите ")
        // Половина ограды — ещё не ограда, но и не текст, который надо читать.
        #expect(SuggestionMarkup.balanced("``") == "")
    }

    @Test("Пункт списка появляется пунктом, даже когда после маркера ещё пусто")
    func anEmptyItemIsAlreadyAnItem() {
        let blocks = SuggestionMarkup.blocks(of: "- первое\n- ")
        #expect(blocks.count == 2)
        #expect(blocks[1].kind == .listItem(marker: "•", indent: 0))
        #expect(blocks[1].text.isEmpty)
    }

    @Test("Число блоков только растёт: показанное не исчезает по ходу генерации")
    func blocksAreOnlyEverAppended() {
        var previous = 0
        for prefix in prefixes(of: technicalAnswer) {
            let count = SuggestionMarkup.blocks(of: prefix).count
            #expect(count >= previous, "блок пропал на «…\(prefix.suffix(24))»")
            previous = count
        }
    }
}

// MARK: - Отрисовка

/// The card is laid out for real here — no window, but the same SwiftUI layout
/// pass. It catches the two things the parser tests cannot: a view that crashes
/// on some shape of markup, and a code block that collapses to nothing because a
/// horizontal scroll view inside a vertical one measured itself wrong.
@MainActor
@Suite("Карточка рисуется")
struct SuggestionCardRenderingTests {

    private func height(of text: String, width: CGFloat = 420) -> CGFloat {
        let renderer = ImageRenderer(
            content: SuggestionMarkupView(text: text).frame(width: width)
        )
        return renderer.nsImage?.size.height ?? 0
    }

    @Test("Блок кода занимает место, а не схлопывается в ноль")
    func acodeBlockIsLaidOut() {
        let without = height(of: "Решение:")
        let with = height(of: "Решение:\n```swift\nlet a = 1\nlet b = 2\n```")
        #expect(without > 0)
        #expect(with > without, "блок кода не занял ни одной строки: \(with) против \(without)")
    }

    @Test("Длинная строка кода не переносится: высота от ширины окна не зависит")
    func alongLineOfCodeDoesNotWrap() {
        let source = "```swift\n" + String(repeating: "let identifier = value; ", count: 12) + "\n```"
        #expect(height(of: source, width: 420) == height(of: source, width: 240))
    }

    @Test("Половина разметки посреди потока рисуется без падения")
    func everyPrefixOfAnAnswerCanBeDrawn() {
        for length in stride(from: 1, through: technicalAnswer.count, by: 7) {
            #expect(height(of: String(technicalAnswer.prefix(length))) > 0)
        }
    }
}

// MARK: - Одна ошибка вместо потока

@MainActor
@Suite("Повтор одной и той же ошибки не множится")
struct SuggestionFeedEntryTests {

    private func failure(_ message: String, text: String = "") -> Suggestion {
        Suggestion(text: text, state: .failed(message), startedAt: Date())
    }

    private let key = LLMFailure.missingKey.message

    @Test("Три нажатия с одной и той же ошибкой — одна карточка")
    func thesameFailureIsShownOnce() {
        let feed = SuggestionFeedEntry.feed(of: [failure(key), failure(key), failure(key)])
        #expect(feed.count == 1)
        #expect(feed[0].repeats == 3)
        #expect(feed[0].isRepeated)
    }

    @Test("Карточка — последняя из повторов: она там, куда смотрит пользователь")
    func thecardIsTheLatestOfTheRun() {
        let first = failure(key)
        let last = failure(key)
        let feed = SuggestionFeedEntry.feed(of: [first, last])
        #expect(feed[0].id == last.id)
        #expect(feed[0].id != first.id)
    }

    @Test("Другая причина — другая карточка")
    func adifferentReasonIsNews() {
        let feed = SuggestionFeedEntry.feed(of: [
            failure(key),
            failure(key),
            failure("Сеть недоступна."),
        ])
        #expect(feed.count == 2)
        #expect(feed[0].repeats == 2)
        #expect(feed[1].repeats == 1)
    }

    @Test("Удачный ответ между отказами разрывает повтор: положение изменилось")
    func asuccessInBetweenBreaksTheRun() {
        let feed = SuggestionFeedEntry.feed(of: [
            failure(key),
            Suggestion(text: "Ответ.", state: .complete, startedAt: Date()),
            failure(key),
        ])
        #expect(feed.count == 3)
        #expect(feed.allSatisfy { $0.repeats == 1 })
    }

    @Test("Оборвавшийся на середине ответ не сворачивается: его дочитывают")
    func ahalfWrittenAnswerIsNeverFoldedAway() {
        let feed = SuggestionFeedEntry.feed(of: [
            failure(key, text: "Начну с оценки сложности"),
            failure(key, text: "Сложность здесь"),
        ])
        #expect(feed.count == 2, "в свёрнутой карточке пропал бы текст, который человек читает")
    }

    @Test("Обычная лента не сворачивается ничем: подсказки все разные")
    func anordinaryFeedIsUntouched() {
        let suggestions = [
            Suggestion(text: "Первая.", state: .complete, startedAt: Date()),
            Suggestion(text: "Вторая.", state: .superseded, startedAt: Date()),
            Suggestion(text: "Третья", startedAt: Date()),
        ]
        let feed = SuggestionFeedEntry.feed(of: suggestions)
        #expect(feed.map(\.id) == suggestions.map(\.id))
        #expect(feed.allSatisfy { !$0.isRepeated })
    }

    @Test("Пустая лента — пустая лента")
    func anemptyFeedStaysEmpty() {
        #expect(SuggestionFeedEntry.feed(of: []).isEmpty)
    }

    @Test("Свёртка живёт в представлении: движок помнит все нажатия")
    func theengineKeepsEveryPress() {
        // Провайдера нет — каждое нажатие возвращает одну и ту же причину.
        let engine = SessionEngine(provider: nil)
        engine.suggestBriefly()
        engine.suggestBriefly()
        engine.suggestBriefly()

        #expect(engine.suggestions.count == 3, "движок ведёт запись нажатий — сворачивает её окно, а не он")
        #expect(SuggestionFeedEntry.feed(of: engine.suggestions).count == 1)
    }
}
