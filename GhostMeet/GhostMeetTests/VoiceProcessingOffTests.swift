import Foundation
import Testing
@testable import GhostMeet

/// Сторож решения ADR-0009: системное эхоподавление не включается никогда.
///
/// Обычным тестом это не проверить. `setVoiceProcessingEnabled(true)` меняет
/// режим самого устройства, и увидеть последствие можно только чужим процессом
/// на живой машине с микрофоном — то есть не в этой сюите. Зато сам вызов виден
/// в исходнике, и именно возвращение вызова — тот отказ, от которого нужна
/// защита: он выглядит как безобидное «включим обратно, оно же чинит протечку»,
/// а платят за него все остальные потребители микрофона, включая браузер, в
/// котором идёт звонок.
///
/// Поэтому тест читает исходник. Это дороже обычной проверки поведения и
/// оправдано ровно одним: цена ошибки невидима изнутри приложения — интервьюер
/// перестаёт слышать кандидата, а кандидат об этом не узнаёт.
@Suite("Системное эхоподавление выключено навсегда")
struct VoiceProcessingOffTests {

    /// Каталог с исходниками приложения, вычисленный от файла этого теста:
    /// `GhostMeet/GhostMeetTests/…` → `GhostMeet/GhostMeet/…`.
    private static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)      // …/GhostMeetTests/VoiceProcessingOffTests.swift
            .deletingLastPathComponent()     // …/GhostMeetTests
            .deletingLastPathComponent()     // …/GhostMeet (SRCROOT)
            .appendingPathComponent("GhostMeet")
    }

    /// Код файла без комментариев.
    ///
    /// Комментарии выброшены не для красоты: объяснить, почему VPIO больше не
    /// включается, невозможно, не назвав вызов по имени, — и первая же попытка
    /// написать этот тест поймала собственную документацию `MicCaptureService`.
    /// Сторожить надо вызов, а не упоминание.
    private func code(of file: String) throws -> String {
        let url = Self.sourceDirectory.appendingPathComponent(file)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Ни один файл захвата не включает VPIO и не настраивает его приглушение")
    func noSourceEnablesVoiceProcessing() throws {
        // Три имени, потому что обойти запрет можно тремя способами, и каждый
        // из них — тот же режим устройства: включить обработку, попросить
        // «включить, но с байпасом», настроить приглушение чужого звука.
        let forbidden = [
            "setVoiceProcessingEnabled",
            "voiceProcessingOtherAudioDuckingConfiguration",
            "kAudioUnitSubType_VoiceProcessingIO",
        ]
        for file in ["Audio/MicCaptureService.swift", "App/SessionController.swift"] {
            let text = try code(of: file)
            for name in forbidden {
                #expect(
                    !text.contains(name),
                    "\(file) снова трогает VPIO через \(name) — см. ADR-0009, платит за это браузер со звонком"
                )
            }
        }
    }

    @Test("Ветки отказа «не удалось включить эхоподавление» больше нет")
    func captureErrorHasNoVoiceProcessingCase() {
        // Отказывать не в чем: включать нечего. Остаются две настоящие причины,
        // и у обеих есть текст для пользователя — молчаливый отказ захвата этот
        // проект уже ловил дважды.
        let reasons: [MicCaptureService.CaptureError] = [
            .inputFormatUnavailable,
            .converterUnavailable,
        ]
        for reason in reasons {
            #expect(reason.errorDescription?.isEmpty == false)
        }
        let text = reasons.compactMap(\.errorDescription).joined(separator: " ")
        #expect(
            !text.lowercased().contains("эха"),
            "текст про эхоподавление ушёл вместе с веткой отказа"
        )
    }

    @Test("Микрофон строится без единого аргумента про эхоподавление")
    func microphoneTakesNoVoiceProcessingKnob() {
        // Флаг, всегда равный false, — обещание, что когда-нибудь он станет
        // true. ADR-0009 закрыл этот вопрос замером, поэтому ручки нет вовсе:
        // конструктор компилируется только с частотой дискретизации.
        let service = MicCaptureService(sampleRate: 16_000)
        #expect(service.channel == .you)
        #expect(!service.isRunning)
    }
}
