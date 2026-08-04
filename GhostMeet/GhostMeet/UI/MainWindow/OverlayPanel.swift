//
//  OverlayPanel.swift
//  GhostMeet
//

import AppKit

/// The overlay window itself.
///
/// It is an `NSPanel` rather than an `NSWindow` because only a panel supports
/// `.nonactivatingPanel`: it can be put on screen and clicked without activating
/// GhostMeet, so text the user is typing in the editor or the call keeps going.
///
/// `canBecomeKey` stays `true` so a future input field (Ask mode, ticket 11) can be
/// typed into, but `becomesKeyOnlyIfNeeded` — set in `OverlayWindowConfiguration.apply(to:)` —
/// means the panel only takes the keyboard when such a field is clicked directly.
/// `canBecomeMain` stays `false`: the overlay is never the app's main window.
final class OverlayPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }
}
