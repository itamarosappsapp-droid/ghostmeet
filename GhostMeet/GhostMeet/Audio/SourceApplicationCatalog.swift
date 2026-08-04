//
//  SourceApplicationCatalog.swift
//  GhostMeet
//

import CoreAudio
import Foundation
import Observation

/// The list of applications the user can pick a source from, kept current.
///
/// Separate from capture on purpose: the picker has to be usable while nothing
/// is being captured — the browser is chosen before the call, not during it —
/// and capture has to keep working while the settings window is closed. What
/// they share is only the stable id of the chosen application.
@MainActor
@Observable
final class SourceApplicationCatalog {

    /// Applications on offer, ones currently making sound first.
    private(set) var applications: [SourceApplication] = []

    @ObservationIgnored private let lister: AudioProcessLister
    @ObservationIgnored private let listenerQueue = DispatchQueue(
        label: "com.ghostmeet.source-catalog"
    )
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    init(lister: AudioProcessLister = CoreAudioProcessLister()) {
        self.lister = lister
    }

    deinit {
        guard let listener else { return }
        CoreAudioProcessLister.stopObservingProcessList(listener, on: listenerQueue)
    }

    /// Re-reads the list right now. Cheap enough to call on every appearance of
    /// the settings screen.
    func refresh() {
        applications = lister.sourceApplications()
    }

    /// Refreshes once and then keeps refreshing whenever an application starts
    /// or stops using audio, so the browser shows up in the picker the moment it
    /// begins playing the call.
    func startTracking() {
        refresh()
        guard listener == nil else { return }
        listener = CoreAudioProcessLister.observeProcessList(on: listenerQueue) { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// The chosen application as it stands now, or `nil` when it is not running.
    func application(withID id: String?) -> SourceApplication? {
        guard let id else { return nil }
        return applications.first { $0.id == id }
    }
}
