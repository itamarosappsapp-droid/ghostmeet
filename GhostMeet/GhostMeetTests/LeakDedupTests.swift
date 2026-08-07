//
//  LeakDedupTests.swift
//  GhostMeetTests
//

import Foundation
import Testing
@testable import GhostMeet

/// Дедупликация по тексту: второй слой защиты от протечки канала.
///
/// Все реплики ниже — **настоящий вывод распознавания**, а не выдуманные
/// строки. Протечка снята микрофоном в расследовании ADR-0009
/// (`scratchpad/mic/leak-*-novpio.wav`), нарезана на реплики теми же правилами,
/// которыми режет `TurnSegmenter`, и распознана той же моделью, которую ставит
/// приложение (WhisperKit large-v3-turbo). Честные повторы и ответы произнесены
/// на ту же реплику собеседника и распознаны тем же проходом.
///
/// Отсюда и порог: он не выбран, а прочитан из зазора между двумя измеренными
/// множествами.
@Suite("Дедупликация по тексту")
struct LeakDedupTests {

    /// Реплика собеседника, которая звучала в динамиках во всех записях.
    static let them = "Расскажите, чем актор в свифте отличается от обычного класса, "
        + "и когда компилятор требует и вейт при обращении к его свойствам."

    /// Протечка, распознанная целиком: полная громкость, −12 дБ и −24 дБ.
    ///
    /// Первая строка длиннее оригинала — запись велась через два проигрывания
    /// подряд, и страховочный флаш отрезал реплику посреди второго.
    static let wholeLeaks = [
        "Расскажите, чем актор в свифте отличается от обычного класса, и когда компилятор "
            + "требует await при обращении к его свойствам. Расскажите,",
        "чем актор в свифте отличается от обычного класса, и когда компилятор требует await "
            + "при обращении к его свойствам.",
        "Расскажите, чем актор в свифте отличается от обычного класса, и когда компилятор "
            + "требует и вейт при обращении к его свойствам.",
        "Расскажите, чем актор в свифте отличается от обычного класса, и когда компилятор "
            + "требует эвейт при обращении к его свойствам?",
    ]

    /// Та же протечка, у которой до распознавания доехала половина: непрерывные
    /// куски той же микрофонной записи.
    static let partialLeaks = [
        "Расскажите, чем актор в Свифте отличается от обычных?",
        "класса, и когда компилятор требует await при обращении к его",
        "актор в свифте отличается от обычного класса, и когда компилятор",
        "Компилятор требует await при обращении к его",
    ]

    /// Честный повтор вопроса — обычный приём на собеседовании, и выбрасывать
    /// его нельзя.
    static let honestRepeats = [
        "Правильно ли я понял, вы спрашиваете про отличие актора от обычного класса?",
        "То есть вопрос про акторы в свифте и про эвейт при обращении к свойствам, да?",
        "Секунду, вы спрашиваете, когда именно компилятор требует await?",
        "Чем актер отличается от обычного класса, сейчас расскажу.",
        "Вы спрашиваете, чем актор в свифте отличается от обычного класса?",
        "Уточню, вопрос про то, когда компилятор требует и вейт при обращении к свойствам актора,",
        "Повторю вопрос, чтобы не ошибиться, чем актор в свифте отличается от обычного класса "
            + "и когда компилятор требует эвейт.",
    ]

    /// Обычный ответ по теме вопроса: слова те же, речь своя.
    static let ordinaryAnswers = [
        "Актор изолирует свое изменяемое состояние, поэтому обращение к его свойствам извне требует эвейт.",
        "В отличие от обычного класса, у актора есть собственный исполнитель, и компилятор "
            + "сам расставляет точки при остановке.",
        "Если обращение идет изнутри самого актора, Вейт не нужен, потому что мы уже на его исполнителе.",
        "Да, конечно.",
        "Сейчас подумаю, секунду.",
    ]

    // MARK: - Хелперы

    /// Собеседник говорит с 0 до 8 секунд, пользователь — поверх него.
    private static func call(user said: String, from start: TimeInterval = 0) -> [Turn] {
        [
            Turn(channel: .them, text: them, timestamp: 0, duration: 8),
            Turn(channel: .you, text: said, timestamp: start, duration: 8),
        ]
    }

    private static func verdict(user said: String, from start: TimeInterval = 0) -> Bool {
        let turns = call(user: said, from: start)
        return LeakDedup.isLeak(turns[1], among: turns)
    }

    // MARK: - Настоящие пары

    @Test("Протечка, распознанная целиком, речью пользователя не считается")
    func wholeLeakIsCaught() {
        for leak in Self.wholeLeaks {
            #expect(Self.verdict(user: leak), "не поймана: \(leak)")
        }
    }

    @Test("Протечка, распознанная наполовину, ловится тоже")
    func halfRecognisedLeakIsCaught() {
        for leak in Self.partialLeaks {
            #expect(Self.verdict(user: leak), "не поймана: \(leak)")
        }
    }

    @Test("Честный повтор вопроса остаётся речью пользователя")
    func honestRepeatSurvives() {
        for repeated in Self.honestRepeats {
            #expect(!Self.verdict(user: repeated), "выброшен честный повтор: \(repeated)")
        }
    }

    @Test("Обычный ответ по теме вопроса остаётся")
    func ordinaryAnswerSurvives() {
        for answer in Self.ordinaryAnswers {
            #expect(!Self.verdict(user: answer), "выброшен ответ: \(answer)")
        }
    }

    /// Зазор, из которого прочитан порог. Проваленный тест здесь означает не
    /// «поправьте число», а «померьте заново».
    @Test("Между протечкой и честной речью остаётся измеренный зазор")
    func measuredGapHolds() {
        let leaks = (Self.wholeLeaks + Self.partialLeaks)
            .map { LeakDedup.coverage(of: $0, in: Self.them) }
        let honest = (Self.honestRepeats + Self.ordinaryAnswers)
            .map { LeakDedup.coverage(of: $0, in: Self.them) }

        // 6 из 7 слов — самая тощая протечка в наборе; 8 из 10 — самый близкий
        // к ней честный повтор. Между ними и живёт порог.
        #expect(leaks.min()! >= 6.0 / 7.0)
        #expect(honest.max()! <= 0.80)
        #expect(leaks.min()! > LeakDedup.coverageThreshold)
        #expect(honest.max()! < LeakDedup.coverageThreshold)
    }

    // MARK: - Устойчивость сравнения

    @Test("Регистр, пунктуация и ё ничего не меняют")
    func normalisationHolds() {
        let shouted = Self.them.uppercased().replacingOccurrences(of: ",", with: "")
        #expect(Self.verdict(user: shouted))
        #expect(LeakDedup.words("Всё, что нужно — ёж!") == ["все", "что", "нужно", "еж"])
    }

    @Test("Слово, распознанное по-другому, реплику не спасает")
    func oneWrongWordIsNotEnough() {
        // «await» приезжает как «и вейт», «эвейт» и «await» в разных проходах —
        // это и есть обычная разница распознавания, ради которой порог не 1.0.
        let leak = "Расскажите, чем актор в свифте отличается от обычного класса, "
            + "и когда компилятор требует эвейт при обращении к его свойствам?"
        #expect(Self.verdict(user: leak))
    }

    // MARK: - Окно соседства

    @Test("Совпадение получасовой давности ничего не значит")
    func matchHalfAnHourAgoMeansNothing() {
        let turns = [
            Turn(channel: .them, text: Self.them, timestamp: 0, duration: 8),
            Turn(channel: .you, text: Self.them, timestamp: 1_800, duration: 8),
        ]
        #expect(!LeakDedup.isLeak(turns[1], among: turns))
    }

    /// Граница, на которой текст бессилен и решает только время.
    ///
    /// Голый кусок вопроса, повторённый вслух, — та же строка, что и протечка.
    /// Отличается он тем, **когда** сказан: протечка звучит одновременно с
    /// собеседником, а повторяют после того, как собеседник замолчал.
    @Test("Голый кусок вопроса, повторённый после собеседника, остаётся")
    func bareFragmentAfterTheQuestionSurvives() {
        let fragment = "Чем актор в свифте отличается от обычного класса?"
        #expect(Self.verdict(user: fragment, from: 0), "одновременно — это протечка")
        #expect(
            !Self.verdict(user: fragment, from: 8 + LeakDedup.neighbourhood + 0.1),
            "после паузы — это повтор вслух"
        )

        // Решающий случай, и раньше он был не покрыт: 0.2 с — это ОБЫЧНАЯ пауза
        // между репликами в разговоре, то есть типичный момент, когда кандидат
        // начинает повторять вопрос вслух. Слова у него при этом совпадают с
        // вопросом дословно — по словам протечку и повтор не различить вовсе.
        // Пока окно было 0.4 с, такой повтор стирался из транскрипта чаще, чем
        // выживал.
        #expect(
            !Self.verdict(user: fragment, from: 8 + 0.2),
            "обычная пауза между репликами — уже не одновременность"
        )
    }

    @Test("Хвост протечки сразу после реплики Them ещё ловится")
    func tailWithinTheWindowIsCaught() {
        let turns = [
            Turn(channel: .them, text: Self.them, timestamp: 0, duration: 8),
            Turn(
                channel: .you,
                text: "Компилятор требует await при обращении к его",
                timestamp: 8 + LeakDedup.neighbourhood * 0.75,
                duration: 0.9
            ),
        ]
        #expect(LeakDedup.isLeak(turns[1], among: turns))
    }

    @Test("Реплика Them, разрезанная надвое, сравнивается целиком")
    func splitQuestionIsComparedAsOne() {
        // Собеседника нарезало страховочным флашем посреди фразы; протечка в
        // `You` при этом одна. Ни одна половина по отдельности реплику не
        // покрывает — покрывают обе вместе.
        let turns = [
            Turn(channel: .them, text: "Расскажите, чем актор в свифте отличается от обычного класса,",
                 timestamp: 0, duration: 4),
            Turn(channel: .them, text: "и когда компилятор требует и вейт при обращении к его свойствам.",
                 timestamp: 4, duration: 4),
            Turn(channel: .you, text: Self.wholeLeaks[1], timestamp: 0.2, duration: 7.8),
        ]
        #expect(LeakDedup.isLeak(turns[2], among: turns))
    }

    // MARK: - Что не считается совпадением

    @Test("Короткое совпадение совпадением не считается")
    func aFewWordsAreNotAMatch() {
        for short in ["Да, конечно.", "Актор в свифте.", "Понял, про акторы."] {
            #expect(!Self.verdict(user: short), "выброшено: \(short)")
        }
    }

    @Test("Реплика Them без слов никого не обвиняет")
    func aTurnWithoutWordsAccusesNobody() {
        let turns = [
            Turn(channel: .them, text: "", timestamp: 0, duration: 8),
            Turn(channel: .you, text: Self.wholeLeaks[0], timestamp: 0, duration: 8),
        ]
        #expect(!LeakDedup.isLeak(turns[1], among: turns))
    }

    @Test("Реплика Them протечкой не бывает")
    func themIsNeverALeak() {
        let turns = [
            Turn(channel: .you, text: Self.them, timestamp: 0, duration: 8),
            Turn(channel: .them, text: Self.them, timestamp: 0, duration: 8),
        ]
        #expect(!LeakDedup.isLeak(turns[1], among: turns))
    }

    @Test("Порядок слов важен: те же слова в другом порядке не совпадение")
    func orderMatters() {
        let shuffled = LeakDedup.words(Self.them).reversed().joined(separator: " ")
        #expect(!Self.verdict(user: shuffled))
    }

    // MARK: - Сторожа чисел

    @Test("Окно соседства короче обычной паузы между репликами — иначе честный повтор считается протечкой")
    @MainActor
    func theWindowIsShorterThanAConversationalPause() {
        // Пауза между репликами в разговоре — около 0.2 с. Протечка звучит
        // ОДНОВРЕМЕННО с собеседником, честный повтор — ПОСЛЕ него, и различает
        // их именно это, а не близость. Окно шире паузы стирало бы из
        // транскрипта собственные слова пользователя чаще, чем нет.
        #expect(LeakDedup.neighbourhood < 0.2)

        // И это НЕ хвост строгого режима, хотя раньше было им. `echoTail` —
        // про то, сколько комната звенит после динамика, то есть факт о
        // микрофоне, а не о границах реплик. Сторож стоит на расхождении, чтобы
        // числа не свели обратно «для единообразия».
        #expect(LeakDedup.neighbourhood != SessionEngine.echoTail)
    }

    @Test("Пороги остались теми, что померили")
    func thresholdsAreTheMeasuredOnes() {
        #expect(LeakDedup.coverageThreshold == 0.83)
        #expect(LeakDedup.minimumOverlap == 5)
    }
}
