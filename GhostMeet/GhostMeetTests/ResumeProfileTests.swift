//
//  ResumeProfileTests.swift
//  GhostMeetTests
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// A model that answers from a script and remembers what it was asked.
///
/// Nothing here ever talks to a real provider: an import spends the user's money
/// and sends their resume somewhere, and a test suite has no business doing
/// either.
private final class ResumeModel: LLMProvider, @unchecked Sendable {

    enum Script {
        case answer(String)
        case failure(any Error)
        /// Ответ доехал и оборвался: так ведёт себя провайдер, упёршийся в
        /// бюджет на последней строке профиля.
        case cutAnswer(String, SuggestionCutoff)
    }

    let name = "Заглушка"
    let capabilities = ProviderCapabilities.textOnly

    private let lock = NSLock()
    private let script: Script
    private var recorded: [SuggestionRequest] = []

    init(_ script: Script) {
        self.script = script
    }

    /// Requests that actually reached the model, in order.
    var requests: [SuggestionRequest] { lock.withLock { recorded } }

    func stream(_ request: SuggestionRequest) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            switch script {
            case .answer(let text):
                // In fragments, like a real stream: the import has to collect
                // them itself.
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    continuation.yield(String(line) + "\n")
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .cutAnswer(let text, let cutoff):
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    continuation.yield(String(line) + "\n")
                }
                continuation.finish(throwing: cutoff)
            }
        }
    }
}

/// A throwaway directory for the resume files a test builds.
private struct Scratch {

    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostMeetResume.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String, as name: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard let data = text.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url)
        return url
    }

    /// A PDF with a real text layer, drawn line by line through Core Text —
    /// the ordinary "exported from a word processor" case.
    func writeTextPDF(_ text: String, as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        var baseline = 720.0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let attributed = NSAttributedString(
                string: String(line),
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            )
            context.textPosition = CGPoint(x: 48, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            baseline -= 20
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A PDF whose only page is a picture — a scanned resume.
    func writeScannedPDF(as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard let bitmap = CGContext(
            data: nil,
            width: 400,
            height: 300,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }

        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        // Bars where the text would be: ink on the page, no characters in it.
        for offset in stride(from: 40, through: 240, by: 40) {
            bitmap.fill(CGRect(x: 40, y: offset, width: 300, height: 6))
        }

        guard let image = bitmap.makeImage(),
              let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 400, height: 300)))
        else { throw CocoaError(.fileWriteUnknown) }

        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// A throwaway `UserDefaults` domain, so no test ever touches the user's own
/// preferences. A struct rather than a closure because half of these tests are
/// async and a `body` closure would have to exist in two flavours.
private struct ScratchDefaults {

    let suite: String
    let defaults: UserDefaults

    init() {
        suite = "GhostMeetResumeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        UserDefaults.standard.removeSuite(named: suite)
    }
}

/// What a well-behaved model answers with — the four labelled lines §8 asks for.
private let modelAnswer = """
Название: Тимлид
Роль: Team lead бэкенд-разработки
Опыт: 8 лет в бэкенде, последние три — тимлид команды из шести человек в финтехе.
Стек: Go, PostgreSQL, Kubernetes, Kafka
"""

// MARK: - Извлечение текста

@Suite("Резюме: извлечение текста")
struct ResumeTextExtractionTests {

    @Test("Текстовый файл читается целиком")
    func plainTextIsRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.write("Роль: SRE\nОпыт: 10 лет", as: "resume.txt")
        let extract = try ResumeDocument.read(at: url)

        #expect(extract.text.contains("SRE"))
        #expect(extract.text.contains("10 лет"))
        #expect(!extract.isTruncated)
    }

    @Test("Markdown читается как текст, вместе с разметкой")
    func markdownIsRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.write("# Иван\n\n## Опыт\n\n- 6 лет в финтехе", as: "cv.md")
        let extract = try ResumeDocument.read(at: url)

        #expect(extract.text.contains("6 лет в финтехе"))
    }

    @Test("PDF с текстовым слоем отдаёт свой текст")
    func pdfWithTextLayerIsRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.writeTextPDF(
            "Backend Engineer\nExperience: 7 years\nStack: Go, PostgreSQL",
            as: "resume.pdf"
        )
        let extract = try ResumeDocument.read(at: url)

        #expect(extract.text.contains("Backend Engineer"))
        #expect(extract.text.contains("PostgreSQL"))
    }

    @Test("Сканированное резюме объясняется словами, а не отдаёт пустоту")
    func scannedPDFIsExplained() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.writeScannedPDF(as: "scan.pdf")

        #expect(throws: ResumeDocument.Failure.imageOnlyPDF) {
            try ResumeDocument.read(at: url)
        }
        let message = ResumeDocument.Failure.imageOnlyPDF.message
        #expect(message.contains("текстового слоя"), "пользователь должен понять, что файл — картинка")
        #expect(message.contains("руками"), "и что делать дальше")
    }

    @Test("Чужой формат назван по имени и не читается наугад")
    func unsupportedFormatIsNamed() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.write("PK\u{3}\u{4}", as: "resume.docx")

        #expect(throws: ResumeDocument.Failure.unsupportedFormat("docx")) {
            try ResumeDocument.read(at: url)
        }
        #expect(ResumeDocument.Failure.unsupportedFormat("docx").message.contains(".pdf"))
    }

    @Test("Пустой файл — это объяснение, а не пустой профиль")
    func emptyFileIsExplained() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.write("   \n\n\t\n", as: "empty.txt")

        #expect(throws: ResumeDocument.Failure.empty) {
            try ResumeDocument.read(at: url)
        }
    }

    @Test("Длинное резюме обрезается, и обрезка видна вызывающему")
    func longResumeIsClipped() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let long = String(repeating: "Опыт работы в компании, задачи и результаты. ", count: 900)
        let url = try scratch.write(long, as: "long.txt")
        let extract = try ResumeDocument.read(at: url)

        #expect(extract.text.count == ResumeDocument.maxCharacters)
        #expect(extract.isTruncated)
        #expect(extract.originalCharacterCount > ResumeDocument.maxCharacters)
    }

    @Test("Резюме в cp1251 не превращается в мусор")
    func windowsEncodedTextIsRead() throws {
        let scratch = Scratch()
        defer { scratch.remove() }

        let url = try scratch.write(
            "Роль: разработчик\nОпыт: 5 лет",
            as: "cp1251.txt",
            encoding: .windowsCP1251
        )
        let extract = try ResumeDocument.read(at: url)

        #expect(extract.text.contains("разработчик"))
        #expect(extract.text.contains("5 лет"))
    }
}

// MARK: - Промпт

@Suite("Резюме: промпт разбора")
struct ResumeProfilePromptTests {

    @Test("Системная часть просит ровно те подписи, которыми профиль записывается")
    func systemAsksForTheProfileShape() {
        let system = ResumeProfilePrompt.system

        for field in UserProfile.Field.allCases {
            #expect(system.contains("\(field.label):"), "подпись «\(field.label)» обязана быть в промпте")
        }
        #expect(system.contains("Название:"), "имя профиля модель тоже предлагает")
        #expect(system.contains("Не переноси персональные данные"))
        #expect(system.contains("Язык профиля — язык резюме"))
    }

    @Test("Запрос несёт резюме и не несёт ни экрана, ни разговора")
    func requestCarriesOnlyTheResume() {
        let request = ResumeProfilePrompt.request(resumeText: "Иван, 8 лет в бэкенде")

        #expect(request.userPrompt.contains("Иван, 8 лет в бэкенде"))
        #expect(request.userPrompt.contains("Собери профиль."))
        #expect(request.screenshot == nil, "разбор резюме не смотрит на экран")
        #expect(!request.userPrompt.contains("Them:"))
        #expect(!request.userPrompt.contains(PromptFragment.screenTextHeading))
        #expect(request.maxTokens == ResumeProfilePrompt.maxTokens)
        #expect(request.maxTokens < AskPrompt.maxTokens, "четыре строки не стоят бюджета режима Ask")
    }

    @Test("Профиль пользователя в этот промпт не дописывается — он им создаётся")
    func systemHasNoResumeContextBlock() {
        #expect(!ResumeProfilePrompt.system.contains("Контекст о пользователе"))
    }

    @Test("Про обрезку сказано только тогда, когда она была")
    func truncationIsMentionedOnlyWhenItHappened() {
        let whole = ResumeProfilePrompt.user(resumeText: "коротко", isTruncated: false)
        let cut = ResumeProfilePrompt.user(resumeText: "длинно", isTruncated: true)

        #expect(!whole.contains("первые"))
        #expect(cut.contains("\(ResumeDocument.maxCharacters)"))
    }
}

// MARK: - Одно представление профиля

@Suite("Профиль: одно представление")
struct ProfileRepresentationTests {

    @Test("Разбор — обратная операция к сборке фрагмента промпта")
    func parsingIsTheInverseOfThePromptFragment() {
        let profile = UserProfile(
            role: "Team lead бэкенд-разработки",
            experience: "8 лет в бэкенде, последние три — тимлид",
            stack: "Go, PostgreSQL, Kubernetes"
        )

        let restored = UserProfile.parsed(from: profile.promptFragment)

        #expect(restored.role == profile.role)
        #expect(restored.experience == profile.experience)
        #expect(restored.stack == profile.stack)
        #expect(restored.promptFragment == profile.promptFragment)
    }

    @Test("Ответ модели разбирается в те же три поля")
    func modelAnswerBecomesTheProfile() {
        let profile = UserProfile.parsed(from: modelAnswer)

        #expect(profile.name == "Тимлид")
        #expect(profile.role == "Team lead бэкенд-разработки")
        #expect(profile.stack == "Go, PostgreSQL, Kubernetes, Kafka")
        #expect(profile.experience.contains("8 лет"))
    }

    @Test("Markdown и английские подписи не мешают разбору")
    func decoratedAndEnglishLabelsAreAccepted() {
        let profile = UserProfile.parsed(from: """
        **Name:** Full-stack
        - **Role:** Senior Full-stack Engineer
        * Experience: 6 years, fintech
        **Stack:** TypeScript, Go, React
        """)

        #expect(profile.name == "Full-stack")
        #expect(profile.role == "Senior Full-stack Engineer")
        #expect(profile.experience == "6 years, fintech")
        #expect(profile.stack == "TypeScript, Go, React")
    }

    @Test("Многострочный опыт остаётся одним полем")
    func multilineValueStaysInItsField() {
        let profile = UserProfile.parsed(from: """
        Роль: Backend
        Опыт: 8 лет в бэкенде.
        Последние три года — тимлид.
        Стек: Go
        """)

        #expect(profile.experience.contains("8 лет в бэкенде."))
        #expect(profile.experience.contains("Последние три года — тимлид."))
        #expect(profile.stack == "Go")
    }

    @Test("Ответ без подписей не превращается в профиль молча")
    func proseYieldsAnEmptyProfile() {
        let profile = UserProfile.parsed(from: """
        Конечно! Этот кандидат — опытный инженер с восемью годами за плечами.
        Он работал в нескольких компаниях и хорошо знает Go.
        """)

        #expect(profile.isEmpty, "из прозы профиль не собирается — это должно быть видно вызывающему")
    }

    @Test("«Не указано» не становится фактом о пользователе")
    func placeholdersDoNotReachThePrompt() {
        let profile = UserProfile.parsed(from: """
        Роль: SRE
        Опыт: не указано
        Стек: —
        """)

        #expect(profile.role == "SRE")
        #expect(profile.experience.isEmpty)
        #expect(profile.stack.isEmpty)
        #expect(!profile.promptFragment.contains("Опыт"))
        #expect(!profile.promptFragment.contains("Стек"))
    }

    @Test("Название профиля остаётся в приложении и не уходит в промпт")
    func theProfileNameNeverReachesTheModel() {
        let profile = UserProfile(name: "Тимлид", role: "Backend", experience: "", stack: "Go")

        #expect(!profile.promptFragment.contains("Тимлид"))
        #expect(!AssistPrompt.system(profile: profile).contains("Тимлид"))
        #expect(AssistPrompt.system(profile: profile).contains("Backend"))
    }
}

// MARK: - Список профилей

@MainActor
@Suite("Профили: список и выбор")
struct ProfileLibraryTests {

    @Test("Новый профиль добавляется и сразу становится выбранным")
    func addingAProfileSelectsIt() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile.name = "Тимлид"

        let added = store.addProfile(named: "Синьор фулстек")

        #expect(store.profiles.count == 2)
        #expect(store.selectedProfileID == added)
        #expect(store.profile.displayName == "Синьор фулстек")
    }

    @Test("В подсказку уходит выбранный профиль, а не первый попавшийся")
    func theSelectedProfileIsTheOneInThePrompt() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile = UserProfile(name: "Тимлид", role: "Team lead", stack: "Go")
        let fullstack = store.addProfile(named: "Фулстек")
        store.profile.role = "Full-stack Engineer"

        #expect(AssistPrompt.system(profile: store.profile).contains("Full-stack Engineer"))
        #expect(!AssistPrompt.system(profile: store.profile).contains("Team lead"))

        store.selectProfile(store.profiles[0].id)

        #expect(AssistPrompt.system(profile: store.profile).contains("Team lead"))
        #expect(store.selectedProfileID != fullstack)
    }

    @Test("Удаление выбранного профиля переводит выбор на соседа")
    func removingTheSelectedProfileMovesTheSelection() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile.name = "Первый"
        let second = store.addProfile(named: "Второй")

        store.removeProfile(second)

        #expect(store.profiles.count == 1)
        #expect(store.profile.name == "Первый")
        #expect(store.selectedProfileID == store.profiles[0].id)
    }

    @Test("Приложение никогда не остаётся вовсе без профиля")
    func theLibraryIsNeverEmpty() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile = UserProfile(name: "Единственный", role: "SRE")

        store.removeProfile(store.selectedProfileID)

        #expect(store.profiles.count == 1)
        #expect(store.profile.isEmpty, "остаётся чистый профиль, а не удалённый")
        #expect(store.selectedProfileID == store.profiles[0].id)
    }

    @Test("Переименование не сбивает выбор и не плодит записи")
    func renamingKeepsIdentity() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let id = store.selectedProfileID

        store.renameProfile(id, to: "Тимлид")

        #expect(store.profiles.count == 1)
        #expect(store.selectedProfileID == id)
        #expect(store.profile.name == "Тимлид")
    }

    @Test("Список и выбор переживают перезапуск")
    func libraryAndSelectionSurviveRestart() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let first = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        first.profile = UserProfile(name: "Тимлид", role: "Team lead", stack: "Go")
        first.addProfile(named: "Фулстек")
        first.profile.role = "Full-stack"
        let chosen = first.selectedProfileID

        let next = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())

        #expect(next.profiles.count == 2)
        #expect(next.selectedProfileID == chosen)
        #expect(next.profile.role == "Full-stack")
        #expect(next.profiles[0].name == "Тимлид")
    }

    @Test("Настройки прежней версии читаются: единственный профиль не теряется")
    func theSingleProfileOfAnOlderBuildIsMigrated() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        // Ровно то, что писала на диск версия с одним профилем.
        let legacy = """
        {"role":"Backend-разработчик","experience":"6 лет, финтех","stack":"Go, PostgreSQL"}
        """
        scratch.defaults.set(Data(legacy.utf8), forKey: "settings.userProfile")

        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())

        #expect(store.profiles.count == 1)
        #expect(store.profile.role == "Backend-разработчик")
        #expect(store.profile.experience == "6 лет, финтех")
        #expect(store.profile.stack == "Go, PostgreSQL")
        #expect(store.selectedProfileID == store.profiles[0].id, "перенесённый профиль остаётся выбранным")

        // И перенос доведён до конца: следующий запуск читает уже список.
        #expect(scratch.defaults.data(forKey: "settings.profileLibrary") != nil)
        #expect(scratch.defaults.data(forKey: "settings.userProfile") == nil)

        let next = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        #expect(next.profile.role == "Backend-разработчик")
    }
}

// MARK: - Разбор резюме в профиль

@MainActor
@Suite("Резюме: разбор в профиль")
struct ResumeImportTests {

    @Test("Разобранный профиль показывается на проверку и ничего пока не меняет")
    func theParsedProfileWaitsForApproval() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет в бэкенде", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile = UserProfile(name: "Черновик", role: "было")
        let before = store.profile
        let model = ResumeModel(.answer(modelAnswer))
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) { model }

        #expect(importer.phase == .review)
        #expect(importer.draft.name == "Тимлид")
        #expect(importer.draft.role == "Team lead бэкенд-разработки")
        #expect(store.profile == before, "до «Применить» настройки не тронуты")
        #expect(model.requests.count == 1)
        #expect(model.requests[0].userPrompt.contains("8 лет в бэкенде"))
    }

    /// Бюджет запроса на профиль — 512 токенов, а последняя строка это стек,
    /// список технологий через запятую. Оборваться там — обычное дело, и
    /// выбрасывать из-за этого весь уже разобранный профиль было бы хуже, чем
    /// показать его с оговоркой. До правки пользователь видел английскую
    /// системную строку об ошибке Swift и пустой лист.
    @Test("Ответ оборвался на последней строке — профиль всё равно собран, с оговоркой")
    func aCutAnswerStillYieldsAProfile() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) {
            ResumeModel(.cutAnswer(modelAnswer, .budget))
        }

        #expect(importer.phase == .review, "разобранный профиль не выбрасывается из-за обрыва")
        #expect(!importer.draft.isEmpty)
        #expect(importer.notice?.contains("лимит токенов") == true, "об обрыве сказано по-русски")
    }

    @Test("Оборвался и ничего не собралось — причина обрыва, а не системная строка")
    func aCutAnswerThatParsesToNothingExplainsItself() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) {
            ResumeModel(.cutAnswer("", .budget))
        }

        #expect(importer.phase == .failed(SuggestionCutoff.budget.message))
    }

    @Test("Применение заполняет тот профиль, который был выбран, и не плодит новых")
    func applyingFillsTheSelectedProfile() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.addProfile(named: "Второй")
        let target = store.selectedProfileID
        let importer = ResumeImport()

        await importer.load(url: url, into: target) { ResumeModel(.answer(modelAnswer)) }
        importer.apply(to: store)

        #expect(store.profiles.count == 2, "профиль заполнен, а не добавлен ещё один")
        #expect(store.selectedProfileID == target)
        #expect(store.profile.name == "Тимлид")
        #expect(store.profile.stack == "Go, PostgreSQL, Kubernetes, Kafka")
        #expect(importer.phase == .idle, "после применения экран возвращается в исходное")
        #expect(importer.draft.isEmpty)
    }

    @Test("Правка перед применением — это то, что сохранится")
    func theUsersEditsWin() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) { ResumeModel(.answer(modelAnswer)) }
        importer.draft.role = "Principal Engineer"
        importer.draft.name = "Мой"
        importer.apply(to: store)

        #expect(store.profile.role == "Principal Engineer")
        #expect(store.profile.name == "Мой")
    }

    @Test("Отказ провайдера объясняется его словами, профиль остаётся прежним")
    func aProviderFailureIsExplained() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.profile = UserProfile(name: "Как было", role: "SRE")
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) {
            ResumeModel(.failure(LLMFailure.missingKey))
        }

        #expect(importer.phase == .failed(LLMFailure.missingKey.message))
        #expect(store.profile.role == "SRE")
        #expect(importer.draft.isEmpty)
    }

    @Test("Из ответа без подписей профиль не собирается, и об этом сказано")
    func anUnparsableAnswerIsReported() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) {
            ResumeModel(.answer("Конечно! Это опытный инженер."))
        }

        guard case .failed(let message) = importer.phase else {
            Issue.record("молчаливый пустой профиль — худший исход из возможных")
            return
        }
        #expect(message.contains("руками"))
        #expect(store.profile.isEmpty)
    }

    @Test("Сканированный PDF не доезжает до модели — и до денег пользователя")
    func aScannedResumeNeverReachesTheModel() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.writeScannedPDF(as: "scan.pdf")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let model = ResumeModel(.answer(modelAnswer))
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) { model }

        #expect(importer.phase == .failed(ResumeDocument.Failure.imageOnlyPDF.message))
        #expect(model.requests.isEmpty)
        #expect(store.profile.isEmpty)
    }

    @Test("Отмена выбрасывает черновик целиком")
    func cancellingDropsTheDraft() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let url = try files.write("Опыт: 8 лет", as: "resume.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) { ResumeModel(.answer(modelAnswer)) }
        importer.cancel()

        #expect(importer.phase == .idle)
        #expect(importer.draft.isEmpty)
        #expect(store.profile.isEmpty)
    }

    @Test("Обрезанное резюме — не молча: об этом сказано и модели, и пользователю")
    func truncationIsSurfaced() async throws {
        let files = Scratch()
        let scratch = ScratchDefaults()
        defer { files.remove(); scratch.remove() }

        let long = String(repeating: "Опыт работы, задачи и результаты. ", count: 1_200)
        let url = try files.write(long, as: "long.txt")
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        let model = ResumeModel(.answer(modelAnswer))
        let importer = ResumeImport()

        await importer.load(url: url, into: store.profile.id) { model }

        #expect(importer.notice?.contains("\(ResumeDocument.maxCharacters)") == true)
        #expect(model.requests[0].userPrompt.contains("только его первые"))
    }
}

// MARK: - Куда уходит резюме

@MainActor
@Suite("Резюме: куда уходят данные")
struct ResumePrivacyNoticeTests {

    @Test("Облачный провайдер назван облаком и по имени")
    func aCloudProviderIsNamed() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.providerSelection = ProviderSelection(presetID: "anthropic")

        #expect(store.providerDestination == .cloud)
        #expect(store.resumePrivacyNote.contains("Anthropic"))
        #expect(store.resumePrivacyNote.contains("покинут эту машину"))
    }

    @Test("Локальный сервер — единственный случай, когда обещано, что данные не уйдут")
    func aLocalServerKeepsTheResume() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.providerSelection = ProviderSelection(presetID: "ollama")

        #expect(store.providerDestination == .localMachine)
        #expect(store.resumePrivacyNote.contains("не выйдет"))
    }

    @Test("CLI не обещает, что данные останутся на машине")
    func aCLIToolMakesNoPromise() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = SettingsStore(defaults: scratch.defaults, secrets: InMemorySecretStore())
        store.providerSelection = ProviderSelection(presetID: "claude-cli")

        #expect(store.providerDestination == .commandLineTool)
        #expect(store.resumePrivacyNote.contains("покинут машину"))
        #expect(!store.resumePrivacyNote.contains("не выйдет"))
    }

    @Test("Решает настроенный адрес, а не название предустановки")
    func theEffectiveBaseURLDecides() throws {
        let localOpenAI = ProviderDestination(
            preset: try #require(ProviderFactory.preset(id: "openai")),
            selection: ProviderSelection(presetID: "openai", baseURL: "http://localhost:1234/v1")
        )
        let remoteOllama = ProviderDestination(
            preset: try #require(ProviderFactory.preset(id: "ollama")),
            selection: ProviderSelection(presetID: "ollama", baseURL: "https://gpu.example.com/v1")
        )

        #expect(localOpenAI == .localMachine)
        #expect(remoteOllama == .cloud, "локальная предустановка на чужом адресе — это уже не локально")
    }
}
