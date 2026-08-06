import Foundation
import Testing
@testable import GhostMeet

// MARK: - Test doubles

/// Stand-in for the session-scoped conversation state `SessionEngine` owns. The
/// point of these tests is that clearing it goes nowhere near the interview
/// context, which was typed in before the call started.
@MainActor
private final class ConversationStub {
    private(set) var turns: [String] = []

    func append(_ turn: String) { turns.append(turn) }

    /// The «Очистить контекст разговора» action — the one on the panic key.
    func clear() { turns.removeAll() }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs `body` against a throwaway `UserDefaults` suite and wipes it afterwards,
/// so tests never touch the user's real preferences.
@MainActor
private func withTemporaryDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let name = "GhostMeetInterviewContextTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
    }
    return try body(defaults)
}

private let filled = InterviewContext(
    stories: """
    Платежи падали по ночам — нашёл дедлок в очереди, переписал на идемпотентные ретраи, \
    отказы упали с 3% до 0.1%.
    """,
    motivation: "Продукт про платежи, знаком по прошлой работе; интересна миграция на Go",
    compensation: "350–400 тысяч на руки",
    questions: "Как устроен онбординг; кто принимает решение по архитектуре"
)

// MARK: - Фрагмент промпта

@Suite("Контекст собеседования · фрагмент промпта")
struct InterviewContextFragmentTests {

    @Test("Пустой контекст не оставляет в промпте ни одной подписи")
    func emptyContextLeavesNothing() {
        #expect(InterviewContext.empty.isEmpty)
        #expect(InterviewContext.empty.promptFragment.isEmpty)
    }

    @Test("Пробелы и переводы строк — это пустота, а не содержимое")
    func whitespaceIsEmptiness() {
        let blank = InterviewContext(
            stories: "   ",
            motivation: "\n",
            compensation: " \n\t ",
            questions: ""
        )

        #expect(blank.isEmpty)
        #expect(blank.promptFragment.isEmpty)
    }

    @Test("Заполненные поля доходят до фрагмента вместе со своими подписями")
    func filledFieldsReachTheFragment() {
        let fragment = filled.promptFragment

        for field in InterviewContext.Field.allCases {
            #expect(fragment.contains("\(field.label):"))
        }
        #expect(fragment.contains("идемпотентные ретраи"))
        #expect(fragment.contains("миграция на Go"))
        #expect(fragment.contains("350–400 тысяч на руки"))
        #expect(fragment.contains("кто принимает решение по архитектуре"))
    }

    @Test("Пустое поле не оставляет подписи с пустым значением")
    func blankFieldLeavesNoLabel() {
        let context = InterviewContext(
            stories: "Разбирал инцидент с потерей платежей",
            motivation: "",
            compensation: "   ",
            questions: "Почему открыта вакансия"
        )
        let fragment = context.promptFragment

        #expect(fragment.contains(InterviewContext.Field.stories.label))
        #expect(fragment.contains(InterviewContext.Field.questions.label))
        // «Ожидания по деньгам:» без значения модель читает как факт: ожиданий
        // нет. Подписи не должно быть вовсе.
        #expect(!fragment.contains(InterviewContext.Field.motivation.label))
        #expect(!fragment.contains(InterviewContext.Field.compensation.label))
        #expect(!fragment.contains("Ожидания по деньгам:"))
    }

    @Test("Ни одна строка фрагмента не заканчивается подписью без значения")
    func noLabelEndsUpValueless() {
        let context = InterviewContext(stories: "Одна история", motivation: "  ")
        let lines = context.promptFragment.split(separator: "\n", omittingEmptySubsequences: false)

        for (index, line) in lines.enumerated() where line.hasSuffix(":") {
            let next = index + 1 < lines.count ? String(lines[index + 1]) : ""
            #expect(!next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Поля идут в объявленном порядке — фрагмент не пересобирается случайно")
    func fieldsKeepTheirOrder() {
        let fragment = filled.promptFragment
        var searchStart = fragment.startIndex

        for field in InterviewContext.Field.allCases {
            let found = fragment.range(of: "\(field.label):", range: searchStart..<fragment.endIndex)
            #expect(found != nil)
            guard let found else { return }
            searchStart = found.upperBound
        }
    }

    @Test("Значение стоит под своей подписью, а не рядом с ней")
    func valueSitsUnderItsLabel() {
        let context = InterviewContext(compensation: "350–400 тысяч на руки")
        #expect(context.promptFragment == "Ожидания по деньгам:\n350–400 тысяч на руки")
    }
}

// MARK: - Контекст и профиль

@MainActor
@Suite("Контекст собеседования и профиль не смешиваются")
struct InterviewContextVersusProfileTests {

    @Test("Фрагменты профиля и контекста не пересекаются подписями")
    func fragmentsDoNotOverlap() {
        let profile = UserProfile(
            role: "Backend-разработчик",
            experience: "6 лет, финтех",
            stack: "Go, PostgreSQL"
        )

        for field in InterviewContext.Field.allCases {
            #expect(!profile.promptFragment.contains(field.label))
        }
        for field in UserProfile.Field.allCases {
            #expect(!filled.promptFragment.contains(field.label))
        }
    }

    @Test("Контекст лежит рядом с профилем: смена активного профиля его не меняет")
    func switchingProfilesKeepsTheContext() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.profile = UserProfile(name: "Тимлид", role: "Тимлид", experience: "8 лет", stack: "Go")
            store.interviewContext = filled

            // Второй профиль — тот же человек, другая шляпа.
            let second = store.addProfile(named: "Синьор фулстек")
            store.profile.role = "Fullstack"

            #expect(store.selectedProfileID == second)
            #expect(store.interviewContext == filled)

            // И обратно: контекст остаётся тем же на любом профиле.
            store.selectProfile(store.profiles[0].id)
            #expect(store.interviewContext == filled)
        }
    }

    @Test("Правка контекста не трогает профиль")
    func editingTheContextLeavesTheProfileAlone() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let profile = UserProfile(role: "SRE", experience: "10 лет", stack: "Terraform")
            store.profile = profile

            store.interviewContext.compensation = "400 тысяч"

            #expect(store.profile == profile)
            #expect(!store.profile.promptFragment.contains("400 тысяч"))
        }
    }

    @Test("Профиль не знает о контексте: в его хранимом виде нет полей контекста")
    func theProfileCarriesNoInterviewFields() {
        let encoded = try! JSONEncoder().encode(
            UserProfile(role: "Backend", experience: "6 лет", stack: "Go")
        )
        let text = String(data: encoded, encoding: .utf8) ?? ""

        for field in InterviewContext.Field.allCases {
            #expect(!text.contains(field.rawValue))
        }
    }
}

// MARK: - Хранение

@MainActor
@Suite("Контекст собеседования · хранение")
struct InterviewContextStorageTests {

    @Test("Свежее хранилище отдаёт пустой контекст")
    func freshStoreHasEmptyContext() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(store.interviewContext == .empty)
            #expect(store.interviewContext.isEmpty)
        }
    }

    @Test("Контекст переживает перезапуск приложения")
    func contextSurvivesRestart() {
        withTemporaryDefaults { defaults in
            SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
                .interviewContext = filled

            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.interviewContext == filled)
        }
    }

    @Test("Настройки, записанные сборкой без контекста, читаются как пустой контекст")
    func settingsWithoutTheKeyReadAsEmpty() {
        withTemporaryDefaults { defaults in
            // Настройки, в которых есть профиль и пороги, но ключа контекста
            // никто никогда не писал, — ровно то, что лежит у пользователя
            // предыдущей сборки.
            let old = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            old.profile = UserProfile(role: "Backend", experience: "6 лет", stack: "Go")
            old.turnSegmentation.pauseThreshold = 1.2

            let upgraded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(upgraded.profile.role == "Backend")
            #expect(upgraded.interviewContext.isEmpty)
            #expect(upgraded.interviewContext == .empty)
        }
    }

    @Test("Запись с половиной полей не теряет вторую половину")
    func partialRecordKeepsWhatItHas() {
        let json = #"{"stories":"Инцидент с платежами","questions":"Почему открыта вакансия"}"#
        let decoded = try! JSONDecoder().decode(InterviewContext.self, from: Data(json.utf8))

        #expect(decoded.stories == "Инцидент с платежами")
        #expect(decoded.questions == "Почему открыта вакансия")
        #expect(decoded.motivation.isEmpty)
        #expect(decoded.compensation.isEmpty)
    }

    @Test("Очистка контекста разговора не стирает контекст собеседования")
    func clearingTheConversationKeepsTheInterviewContext() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.interviewContext = filled

            let conversation = ConversationStub()
            conversation.append("Them: расскажите случай из практики")
            conversation.clear()

            #expect(conversation.turns.isEmpty)
            #expect(store.interviewContext == filled)
            // И он действительно на диске, а не только в памяти.
            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.interviewContext == filled)
        }
    }

    @Test("Отдельная кнопка очищает контекст, но не профиль")
    func explicitClearWipesOnlyTheContext() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let profile = UserProfile(role: "Backend", experience: "6 лет", stack: "Go")
            store.profile = profile
            store.interviewContext = filled

            store.clearInterviewContext()

            #expect(store.interviewContext.isEmpty)
            #expect(store.profile == profile)
            // Очистка тоже переживает перезапуск — иначе поля вернулись бы.
            let reloaded = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            #expect(reloaded.interviewContext.isEmpty)
            #expect(reloaded.profile.role == "Backend")
        }
    }

    @Test("Изменение контекста видно наблюдателю сразу")
    func contextChangeIsObservable() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let notified = Box(false)

            withObservationTracking {
                _ = store.interviewContext
            } onChange: {
                notified.value = true
            }

            store.interviewContext.motivation = "Продукт про платежи"
            #expect(notified.value)
        }
    }
}

// MARK: - Экран настроек

@MainActor
@Suite("Контекст собеседования на экране настроек")
struct InterviewContextSettingsScreenTests {

    @Test("У секции есть якорь, на который можно сослаться")
    func theSectionHasAnAnchor() {
        #expect(SettingsSection.allCases.contains(.interviewContext))
        // Сразу за профилем: контекст читается как продолжение профиля и
        // отличается от него только пояснением наверху секции.
        let order = SettingsSection.allCases
        #expect(order.firstIndex(of: .interviewContext) == (order.firstIndex(of: .profile).map { $0 + 1 }))
    }

    @Test("Каждое поле модели названо на экране своей подписью")
    func everyFieldHasALabel() {
        for field in InterviewContext.Field.allCases {
            #expect(!field.label.isEmpty)
        }
        #expect(Set(InterviewContext.Field.allCases.map(\.label)).count
            == InterviewContext.Field.allCases.count)
    }

    @Test("Полей ровно четыре — анкету длиннее никто не заполнит")
    func thereAreExactlyFourFields() {
        #expect(InterviewContext.Field.allCases.count == 4)
    }
}

// MARK: - Дорога до промпта

/// That the заготовки actually reach a model, through the composer the app
/// itself builds — not merely that the type can render itself.
///
/// The wiring is the whole point of the field: a context that is stored, shown
/// and never sent is four text areas that do nothing.
@MainActor
@Suite("Контекст собеседования доезжает до промпта")
struct InterviewContextReachesThePromptTests {

    /// Built the way the composition root builds it: both the profile and the
    /// заготовки read from `SettingsStore` at request time, so an edit made
    /// between two presses reaches the second one.
    private func composer(_ store: SettingsStore) -> PromptComposer {
        PromptComposer(profile: { store.profile }, interviewContext: { store.interviewContext })
    }

    private var transcript: [Turn] {
        [Turn(channel: .them, text: "Расскажите случай из практики.", timestamp: 0, duration: 1.2)]
    }

    @Test("Заполненный контекст уходит в system-промпт обоих жанров, рядом с профилем")
    func bothGenresCarryTheContextBesideTheProfile() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.profile = UserProfile(role: "Тимлид", stack: "Go, Postgres")
            store.interviewContext = filled

            for ask in [SuggestionAsk.brief, .detailed, .question("что сказать про деньги?")] {
                let system = composer(store)
                    .compose(ask, transcript: transcript, screen: .none, accepting: .textOnly)
                    .systemPrompt

                #expect(system.contains("Роль: Тимлид"), "профиль остаётся на месте")
                #expect(system.contains(PromptFragment.interviewContextHeading))
                #expect(system.contains("350–400 тысяч на руки"))
                #expect(system.contains("Как устроен онбординг"))
            }
        }
    }

    @Test("Правку контекста между двумя нажатиями видит уже второе")
    func anEditBetweenTwoPressesReachesTheSecond() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            let composer = composer(store)

            let before = composer
                .compose(.brief, transcript: transcript, screen: .none, accepting: .textOnly)
                .systemPrompt
            #expect(!before.contains(PromptFragment.interviewContextHeading))

            store.interviewContext.compensation = "не ниже 350"

            let after = composer
                .compose(.brief, transcript: transcript, screen: .none, accepting: .textOnly)
                .systemPrompt
            #expect(after.contains("Ожидания по деньгам:\nне ниже 350"))
        }
    }

    @Test("Задаче с экрана заготовки не достаются: их там некому произносить")
    func solveOnScreenGetsNeitherProfileNorContext() {
        withTemporaryDefaults { defaults in
            let store = SettingsStore(defaults: defaults, secrets: InMemorySecretStore())
            store.profile = UserProfile(role: "Тимлид")
            store.interviewContext = filled

            let system = composer(store)
                .compose(.screenTask, transcript: transcript, screen: .none, accepting: .textOnly)
                .systemPrompt

            #expect(system == SolvePrompt.system)
            #expect(!system.contains(PromptFragment.interviewContextHeading))
            #expect(
                !system.contains("Контекст о пользователе"),
                "ответ уходит в редактор, а не в реплику: и резюме, и зарплатные ожидания там только шум"
            )
        }
    }
}
