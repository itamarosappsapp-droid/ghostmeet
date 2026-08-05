//
//  HotkeyAction.swift
//  GhostMeet
//

import Carbon.HIToolbox
import Foundation

/// What a global hotkey does.
///
/// Four, and deliberately no more: hotkeys are the **secondary** path in
/// GhostMeet (ADR-0003) — the suggestion loop fires on its own, and reaching for
/// the keyboard on camera is exactly what the proactive loop exists to avoid.
/// These four are the things the loop cannot decide for the user.
nonisolated enum HotkeyAction: String, CaseIterable, Codable, Sendable, Identifiable {

    /// Show or hide the overlay. **Capture keeps running while it is hidden** —
    /// this is the panic key, not a stop button.
    case toggleVisibility
    /// Start listening, waiting for the recognition model if it is not loaded yet.
    case startListening
    /// Stop listening.
    case stopListening
    /// Forget the conversation so far. The `Профиль` survives it — it belongs to
    /// the user, not to the call.
    case clearContext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleVisibility: "Показать / скрыть окно"
        case .startListening: "Начать прослушивание"
        case .stopListening: "Остановить прослушивание"
        case .clearContext: "Очистить контекст разговора"
        }
    }

    /// One line of what actually happens, for the row in the interface. The
    /// panic key's line is the important one: users assume hiding stops
    /// recording, and here it does not.
    var summary: String {
        switch self {
        case .toggleVisibility:
            "Прячет окно с глаз мгновенно. Захват при этом продолжается — реплики пишутся дальше."
        case .startListening:
            "Если модель распознавания ещё готовится, прослушивание включится само, как только она будет готова."
        case .stopListening:
            "Останавливает оба канала и закрывает начатую реплику."
        case .clearContext:
            "Стирает транскрипт и подсказки текущего звонка. Профиль остаётся."
        }
    }

    /// What ships. Chosen to avoid chords the user's other applications need:
    /// a global hotkey outranks the focused app, so ⌘⇧S here would take «Сохранить
    /// как…» away from every editor on the machine.
    ///
    /// The panic key is the exception to the ⌘⌥ pattern: it has to be reachable
    /// in one motion, on camera, without looking down.
    var defaultHotkey: Hotkey {
        switch self {
        case .toggleVisibility: Hotkey(kVK_ANSI_Backslash, [.command])
        case .startListening: Hotkey(kVK_ANSI_L, [.command, .option])
        case .stopListening: Hotkey(kVK_ANSI_Period, [.command, .option])
        case .clearContext: Hotkey(kVK_ANSI_K, [.command, .option])
        }
    }

    /// The chords offered for this action in the interface.
    ///
    /// A fixed list rather than a "press the keys" recorder: the overlay is a
    /// `.nonactivatingPanel` that deliberately never takes the keyboard focus
    /// (that is what keeps typing in the call working), so it is the one window
    /// in the app that cannot reliably read a key press. A picker needs no focus.
    var candidates: [Hotkey] {
        var chords = [defaultHotkey]
        chords.append(contentsOf: Self.sharedCandidates.filter { $0 != defaultHotkey })
        return chords
    }

    /// Chords that are free of standard system and browser shortcuts, offered for
    /// every action.
    private static let sharedCandidates: [Hotkey] = [
        Hotkey(kVK_ANSI_Backslash, [.command]),
        Hotkey(kVK_ANSI_Backslash, [.command, .option]),
        Hotkey(kVK_ANSI_L, [.command, .option]),
        Hotkey(kVK_ANSI_Period, [.command, .option]),
        Hotkey(kVK_ANSI_K, [.command, .option]),
        Hotkey(kVK_ANSI_G, [.command, .option]),
        Hotkey(kVK_ANSI_J, [.command, .option]),
        Hotkey(kVK_ANSI_Quote, [.command, .option]),
        Hotkey(kVK_F13, [.control, .option]),
        Hotkey(kVK_F14, [.control, .option]),
        Hotkey(kVK_F15, [.control, .option]),
        Hotkey(kVK_ANSI_1, [.control, .option, .command]),
        Hotkey(kVK_ANSI_2, [.control, .option, .command]),
        Hotkey(kVK_ANSI_3, [.control, .option, .command]),
        Hotkey(kVK_ANSI_4, [.control, .option, .command])
    ]
}

/// Which chord runs which action, as the user left it.
///
/// An absent action is an action with **no** hotkey, and that is a state the user
/// can choose: a binding they cleared must not come back at the next launch,
/// which is why the defaults are applied when nothing has ever been stored and
/// never per-action afterwards.
nonisolated struct HotkeyBindings: Codable, Equatable, Sendable {

    /// Keyed by the raw value rather than by `HotkeyAction`, so the stored JSON
    /// is a plain object and an action added by a later version simply does not
    /// appear instead of failing the whole decode.
    private var storage: [String: Hotkey]

    init(_ pairs: [HotkeyAction: Hotkey] = [:]) {
        storage = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key.rawValue, $0.value) })
    }

    /// What ships on a first launch.
    static var `default`: HotkeyBindings {
        HotkeyBindings(
            Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultHotkey) })
        )
    }

    subscript(action: HotkeyAction) -> Hotkey? {
        get { storage[action.rawValue] }
        set { assign(newValue, to: action) }
    }

    /// Every action that currently has a chord.
    var assigned: [HotkeyAction: Hotkey] {
        var result: [HotkeyAction: Hotkey] = [:]
        for (raw, hotkey) in storage {
            guard let action = HotkeyAction(rawValue: raw) else { continue }
            result[action] = hotkey
        }
        return result
    }

    /// Which action a chord currently runs, if any.
    func action(boundTo hotkey: Hotkey) -> HotkeyAction? {
        assigned.first { $0.value == hotkey }?.key
    }

    /// Binds a chord to an action, or clears the binding with `nil`.
    ///
    /// A chord already used by another action is **taken** from it rather than
    /// refused. Two actions on one chord is not a state the system can honour —
    /// only one of them would ever fire — and a silent refusal would leave the
    /// user pressing a key that does the wrong thing.
    mutating func assign(_ hotkey: Hotkey?, to action: HotkeyAction) {
        guard let hotkey else {
            storage.removeValue(forKey: action.rawValue)
            return
        }
        guard hotkey.isValid else { return }
        for (raw, existing) in storage where existing == hotkey && raw != action.rawValue {
            storage.removeValue(forKey: raw)
        }
        storage[action.rawValue] = hotkey
    }
}
