//
//  Hotkey.swift
//  GhostMeet
//

import Carbon.HIToolbox
import Foundation

/// The modifier keys of a global chord.
///
/// A bit layout of our own rather than Carbon's or AppKit's: this value is
/// written to `UserDefaults` and has to survive the app being rebuilt against a
/// different SDK. Translation to Carbon happens at the edge, in `carbonValue`.
nonisolated struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {

    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let control = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let shift = HotkeyModifiers(rawValue: 1 << 2)
    static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// The same set in the bit layout `RegisterEventHotKey` expects.
    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        if contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    /// Whether the chord may be taken away from every other application.
    ///
    /// A global hotkey outranks the focused app, so a chord without ⌘, ⌥ or ⌃
    /// would swallow ordinary typing everywhere on the machine — `⇧K` would stop
    /// producing a capital K in the browser the user is being interviewed in.
    /// Shift alone is therefore not enough, and no modifier at all certainly is
    /// not.
    var isStrongEnough: Bool {
        !intersection([.command, .option, .control]).isEmpty
    }

    /// The symbols in the order macOS prints them: ⌃⌥⇧⌘.
    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// One global key combination.
///
/// Stored as a virtual key code rather than as a character: the code is what
/// `RegisterEventHotKey` takes, and it does not move when the user switches to a
/// Russian keyboard layout mid-call — which, in this app's scenario, is a thing
/// that happens between two sentences.
nonisolated struct Hotkey: Codable, Hashable, Sendable {

    /// Virtual key code (`kVK_…`).
    var keyCode: UInt16

    var modifiers: HotkeyModifiers

    init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Convenience for the defaults and for tests, where the key is known by name.
    init(_ key: Int, _ modifiers: HotkeyModifiers) {
        self.init(keyCode: UInt16(key), modifiers: modifiers)
    }

    /// Whether this chord may be registered at all — see
    /// `HotkeyModifiers.isStrongEnough`.
    var isValid: Bool { modifiers.isStrongEnough }

    /// What the user sees, e.g. `⌘⌥L`.
    var displayString: String { modifiers.symbols + Self.label(for: keyCode) }

    /// The printable name of a virtual key code.
    ///
    /// A table and not `UCKeyTranslate`: the live keyboard layout would make the
    /// label move under the user's feet when they switch to Cyrillic, while the
    /// chord itself does not move at all. The table describes the physical
    /// keyboard, which is what the chord is bound to.
    static func label(for keyCode: UInt16) -> String {
        if let named = names[Int(keyCode)] { return named }
        return "#\(keyCode)"
    }

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
        kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "⎋", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}
