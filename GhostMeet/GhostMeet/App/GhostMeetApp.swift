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
        // The overlay itself is not a SwiftUI scene: a `WindowGroup` cannot express a
        // non-activating panel with `sharingType = .none`, so it is built in AppKit by
        // `OverlayWindowController` from the app delegate.
        //
        // TODO(06 — Настройки и Keychain): put the settings UI here instead of EmptyView.
        // In accessory mode there is no menu bar, so it has to be opened programmatically.
        Settings {
            EmptyView()
        }
    }
}

/// Brings the app up as an accessory: no Dock icon, no entry in the app switcher,
/// and — the part that matters during a call — GhostMeet never becomes the active
/// app, so the keyboard focus stays with the call or the editor.
final class GhostMeetAppDelegate: NSObject, NSApplicationDelegate {

    private let overlayWindowController = OverlayWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before the first window appears, otherwise the Dock icon flashes.
        //
        // NOTE: the same thing is normally declared as `LSUIElement` in Info.plist.
        // That key is not in the plist yet; adding it there would make the accessory
        // mode take effect from the very first frame of launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlayWindowController.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hiding the overlay (panic hotkey, ticket 10) must not quit the app —
        // capture keeps running while the window is off screen.
        false
    }
}
