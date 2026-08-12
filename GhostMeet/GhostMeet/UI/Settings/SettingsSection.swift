//
//  SettingsSection.swift
//  GhostMeet
//

import Foundation

/// A section of the settings screen, named so that somewhere else in the app can
/// point at it.
///
/// The readiness strip states a fact and offers to change it; without this the
/// offer lands the user in a form of eight sections and leaves them to find the
/// one that was just mentioned. The screen is one `Form` — see `SettingsView` —
/// and these are its anchors, in the order they are drawn.
enum SettingsSection: String, CaseIterable, Sendable {
    case profile
    case interviewContext
    case captureBackend
    case sourceApplication
    case recognition
    case provider
    case providerKey
    case segmentation
    case updates
}

/// Opening the settings window, optionally at a section.
///
/// `nil` means "just open it": the gear in the overlay header is a way in, not a
/// way to a particular control.
typealias OpenSettings = (SettingsSection?) -> Void

/// Which section the settings screen has been asked to show.
///
/// A request rather than a value, because the same section can be asked for
/// twice in a row — press the provider field, scroll away, press it again — and
/// a plain `SettingsSection?` would look unchanged the second time and scroll
/// nowhere. The token is what makes the second press a new request.
@Observable
final class SettingsNavigation {

    struct Request: Equatable, Sendable {
        let section: SettingsSection
        /// Increments with every request; see the type's note.
        let token: Int
    }

    private(set) var request: Request?

    private var issued = 0

    func reveal(_ section: SettingsSection) {
        issued += 1
        request = Request(section: section, token: issued)
    }
}
