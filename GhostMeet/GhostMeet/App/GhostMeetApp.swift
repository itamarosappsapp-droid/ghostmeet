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

    /// Where everything the app remembers is written.
    ///
    /// The user's own domain for an ordinary launch, a throwaway one when the
    /// process was started by the test runner — see `AppDefaults`. Every store
    /// below is built on this one value, which is what keeps a test run out of
    /// the user's window geometry and settings.
    private let defaults = AppDefaults.forCurrentProcess()

    /// The one settings store of the app: the profile, the thresholds and the
    /// presence of the provider key.
    private lazy var settings = SettingsStore(defaults: defaults)

    /// Model choice and download progress of the recogniser. Shared between the
    /// session, which transcribes with it, and the settings screen, which picks
    /// the model and shows how far its download has got.
    private lazy var recognition = SpeechModelStatus(store: settings)

    /// The one session: microphone in, transcript out.
    ///
    /// It is handed the model's phase, not just the recogniser: listening that
    /// starts before the model is loaded loses the first thing said, because a
    /// turn closed too early is refused outright rather than queued.
    private lazy var session = SessionController.dualChannel(
        settings: settings,
        recognizer: recognition.recognizer,
        isRecognitionReady: { [weak self] in self?.recognition.phase.isReady ?? false }
    )

    private lazy var settingsWindowController = SettingsWindowController(
        store: settings,
        recognition: recognition
    )

    /// The five global chords and what they do.
    ///
    /// Built on Carbon's `RegisterEventHotKey`, which needs **no permission** —
    /// see `CarbonHotkeyRegistry`. The app already asks for four grants; a fifth
    /// (Accessibility, which `NSEvent`'s global monitor requires) for a secondary
    /// control path is not a trade worth making.
    private lazy var hotkeys = HotkeyCenter(store: settings)

    private lazy var overlayWindowController = OverlayWindowController(
        session: session,
        recognition: recognition,
        hotkeys: hotkeys,
        openSettings: { [weak self] in self?.settingsWindowController.show() },
        stateStore: WindowStateStore(defaults: defaults)
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

        // Same for the provider: picking another model — or fixing its address —
        // takes effect on the next suggestion, without relaunching the app.
        session.followProviderSelection(of: settings)

        // Load the recognition model now rather than on the first turn.
        //
        // Preparation is lazy by default, and a turn closed before the model is
        // ready is rejected outright rather than queued — otherwise a pile of
        // stale suggestions would land once loading finished. Left alone, that
        // means the first thing said in every session is lost, which in an
        // interview is the opening question. The model is already on disk by
        // then, so this only pays for loading it into memory.
        recognition.prepare()

        // How far preparation has got is reported in the overlay and nowhere
        // else. GhostMeet posts no system notifications at all — macOS draws
        // banners on top of everything, including the window the user is
        // sharing, and one banner is all it takes to give the app away
        // (ADR-0004). That holds for good news as much as for failures.

        // Listening is not started here on purpose: the microphone prompt would
        // come up before the user has asked for anything, and the first thing
        // they see would be a permission dialog rather than the overlay.

        wireHotkeys()

        overlayWindowController.show()
    }

    /// Connects the five chords to the things they drive, and registers them
    /// with the system.
    ///
    /// The composition root is the only place that knows all three participants:
    /// the window (panic), the session (listening) and the conversation
    /// (clearing). `HotkeyCenter` deliberately knows none of them.
    private func wireHotkeys() {
        hotkeys.actions = HotkeyActions(
            // Hiding is only the window. Capture keeps running — see
            // `OverlayWindowController.toggleVisibility()`.
            toggleVisibility: { [weak self] in self?.overlayWindowController.toggleVisibility() },
            // `startWhenRecognitionIsReady()` and not `start()`: a chord pressed
            // while the model is still loading has to mean "listen to this call",
            // not "listen now, or silently do nothing". A turn closed before the
            // model is ready is refused outright, so the plain `start()` here
            // would cost the user the opening question of the interview.
            startListening: { [weak self] in self?.session.startWhenRecognitionIsReady() },
            stopListening: { [weak self] in self?.session.stop() },
            // The one manual mode that is wanted with the hands on someone
            // else's editor rather than on this window — see `HotkeyAction`.
            solveOnScreen: { [weak self] in self?.session.solveOnScreen() },
            clearContext: { [weak self] in self?.session.clearContext() }
        )
        hotkeys.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the overlay (panic hotkey, ticket 10) must not quit the app —
        // capture keeps running while the window is off screen.
        false
    }
}
