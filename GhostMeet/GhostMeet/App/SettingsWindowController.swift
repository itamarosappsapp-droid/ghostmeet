//
//  SettingsWindowController.swift
//  GhostMeet
//

import AppKit
import SwiftUI

/// Owns the settings window.
///
/// GhostMeet runs as an accessory app, so it has no menu bar of its own: the
/// standard «Настройки…» item does not exist and SwiftUI's `Settings` scene is
/// unreachable. The only way in is the button in the overlay, which calls this.
///
/// Unlike the overlay this is an ordinary window and the opposite rules apply:
/// it is meant to be typed into, so it activates the app and takes the keyboard
/// focus. What it keeps from the overlay is `sharingType = .none` — the profile
/// and the state of the provider key have no business turning up in a shared
/// window either.
///
/// The window lives on the file-system-synchronised `App/` group rather than
/// `UI/Settings/` because it is window plumbing, not the settings screen itself;
/// `SettingsView` is what it hosts and knows nothing about windows.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private static let frameAutosaveName = "GhostMeet.settings.window"

    private let store: SettingsStore

    /// Model choice and download progress — live state of the recogniser rather
    /// than a setting, which is why it arrives beside the store and not inside it.
    private let recognition: SpeechModelStatus

    private var window: NSWindow?

    init(store: SettingsStore, recognition: SpeechModelStatus) {
        self.store = store
        self.recognition = recognition
        super.init()
    }

    /// Puts the settings window up, focused and in front.
    func show() {
        let window = loadedWindow()
        // Cooperative activation may refuse an accessory app that the user never
        // clicked in the Dock — and the click that got us here landed in a
        // non-activating panel. `orderFrontRegardless` is what guarantees the
        // window is on screen even then.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Whether the window is currently on screen.
    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - Window construction

    private func loadedWindow() -> NSWindow {
        if let window { return window }
        let created = makeWindow()
        window = created
        return created
    }

    private func makeWindow() -> NSWindow {
        let content = SettingsView(store: store, recognition: recognition)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Настройки GhostMeet"

        // Same content protection as the overlay: excluded from screen capture.
        window.sharingType = .none

        // Closing the window must not destroy it, and must not quit the app:
        // capture keeps running while settings are out of sight.
        window.isReleasedWhenClosed = false
        window.delegate = self

        window.center()
        if window.setFrameAutosaveName(Self.frameAutosaveName) {
            _ = window.setFrameUsingName(Self.frameAutosaveName)
        }
        return window
    }
}
