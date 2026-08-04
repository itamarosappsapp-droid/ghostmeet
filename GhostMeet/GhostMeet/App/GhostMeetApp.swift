//
//  GhostMeetApp.swift
//  GhostMeet
//
//  Created by Mikhail Abroskin on 03/08/2026.
//

import AppKit
import SwiftUI

@main
struct GhostMeetApp: App {

    @NSApplicationDelegateAdaptor(GhostMeetAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Neither window of the app is a SwiftUI scene.
        //
        // The overlay cannot be one: a `WindowGroup` cannot express a non-activating
        // panel with `sharingType = .none`, so it is built in AppKit by
        // `OverlayWindowController` from the app delegate.
        //
        // The settings window is not one either: in accessory mode there is no menu
        // bar, so this `Settings` scene has no item to be opened from. It stays as an
        // empty placeholder — `SettingsWindowController` puts `SettingsView` on screen
        // when the user presses the gear in the overlay.
        Settings {
            EmptyView()
        }
    }
}

/// Brings the app up as an accessory: no Dock icon, no entry in the app switcher,
/// and — the part that matters during a call — GhostMeet never becomes the active
/// app, so the keyboard focus stays with the call or the editor.
final class GhostMeetAppDelegate: NSObject, NSApplicationDelegate {

    /// The one settings store of the app: the profile, the thresholds and the
    /// presence of the provider key.
    private let settings = SettingsStore.shared

    /// Model choice and download progress of the recogniser. Shared between the
    /// session, which transcribes with it, and the settings screen, which picks
    /// the model and shows how far its download has got.
    private let recognition = SpeechModelStatus.shared

    /// The one session: microphone in, transcript out.
    private lazy var session = SessionController.microphone(
        settings: settings,
        recognizer: recognition.recognizer
    )

    private lazy var settingsWindowController = SettingsWindowController(
        store: settings,
        recognition: recognition
    )

    private lazy var overlayWindowController = OverlayWindowController(
        session: session,
        openSettings: { [weak self] in self?.settingsWindowController.show() }
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before the first window appears, otherwise the Dock icon flashes.
        //
        // NOTE: the same thing is normally declared as `LSUIElement` in Info.plist.
        // That key is not in the plist yet; adding it there would make the accessory
        // mode take effect from the very first frame of launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Thresholds edited in the settings window reach the engine on their own
        // from here on; nothing else has to know a change happened.
        session.followThresholds(of: settings)

        // Listening is not started here on purpose: the microphone prompt would
        // come up before the user has asked for anything, and the first thing
        // they see would be a permission dialog rather than the overlay.
        overlayWindowController.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the overlay (panic hotkey, ticket 10) must not quit the app —
        // capture keeps running while the window is off screen.
        false
    }
}
