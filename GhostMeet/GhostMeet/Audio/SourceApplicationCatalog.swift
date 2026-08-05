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
///
/// The list depends on the capture backend, and not cosmetically: Core Audio
/// knows every process that opened an output device, ScreenCaptureKit knows
/// every application that owns a window, and neither list contains the other.
/// Offering the wrong one is the worst failure this screen has — the user picks
/// an application the selected backend cannot see, the channel stays silent, and
/// nothing on screen says why.
@MainActor
@Observable
final class SourceApplicationCatalog {

    /// Applications on offer, ones currently making sound first.
    private(set) var applications: [SourceApplication] = []

    /// Why the list cannot be built at all, in words meant for the user, or
    /// `nil` when it could. In practice this is the missing Screen Recording
    /// grant, which is what ScreenCaptureKit refuses on — and since that backend
    /// is the default, it is the very first thing a fresh machine runs into.
    private(set) var unavailableReason: String?

    /// Which backend the list is built for. Changing it rebuilds the list, so
    /// the picker never keeps offering entries the new backend cannot see.
    var backend: ThemCaptureBackend {
        didSet {
            guard backend != oldValue else { return }
            refresh()
        }
    }

    @ObservationIgnored private let lister: AudioProcessLister
    @ObservationIgnored private let shareable: any ShareableApplicationLister
    @ObservationIgnored private let listenerQueue = DispatchQueue(
        label: "com.ghostmeet.source-catalog"
    )
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        backend: ThemCaptureBackend = .default,
        lister: AudioProcessLister = CoreAudioProcessLister(),
        shareable: any ShareableApplicationLister = SCKAudioStream()
    ) {
        self.backend = backend
        self.lister = lister
        self.shareable = shareable
    }

    deinit {
        guard let listener else { return }
        CoreAudioProcessLister.stopObservingProcessList(listener, on: listenerQueue)
    }

    /// Re-reads the list right now. Cheap enough to call on every appearance of
    /// the settings screen.
    ///
    /// Synchronous under the tap and asynchronous under ScreenCaptureKit,
    /// because that is what the two APIs are: `SCShareableContent` is a round
    /// trip through the window server. `refreshCompleted()` is how a caller
    /// waits for the slow one without sleeping.
    func refresh() {
        refreshTask?.cancel()
        let backend = backend
        switch backend {
        case .processTap:
            refreshTask = nil
            apply(lister.sourceApplications(), unavailable: nil, builtFor: backend)
        case .screenCaptureKit:
            refreshTask = Task { [weak self] in await self?.refreshShareable(builtFor: backend) }
        }
    }

    /// Waits for a refresh that has already been asked for.
    ///
    /// Mirrors `SCKCaptureService.waitForAttach()`: the ScreenCaptureKit list is
    /// an `await` all the way down, so whoever needs to know how it ended has to
    /// be able to wait instead of sleeping.
    func refreshCompleted() async {
        await refreshTask?.value
    }

    /// Refreshes once and then keeps refreshing whenever an application starts
    /// or stops using audio, so the browser shows up in the picker the moment it
    /// begins playing the call.
    ///
    /// The Core Audio notification is used under both backends. ScreenCaptureKit
    /// has no "the applications changed" signal of its own, and the process list
    /// moving is the same event from another angle: something just started or
    /// stopped making noise.
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

    // MARK: - ScreenCaptureKit

    private func refreshShareable(builtFor backend: ThemCaptureBackend) async {
        do {
            let offered = try await shareable.shareableApplications()
            guard !Task.isCancelled else { return }
            apply(
                SourceApplication.offered(
                    shareable: offered,
                    applications: lister.runningApplications(),
                    audioProcesses: lister.audioProcesses()
                ),
                unavailable: nil,
                builtFor: backend
            )
        } catch {
            guard !Task.isCancelled else { return }
            // `SCShareableContent` has one failure that happens in practice, and
            // it is the one that matters: Screen Recording was never granted. It
            // reports it by throwing and leaving no list at all, so unless the
            // reason reaches the screen the user is left staring at an empty
            // picker with nothing to act on.
            apply([], unavailable: Self.message(for: error), builtFor: backend)
        }
    }

    /// Publishes a result, unless the backend was switched while it was in
    /// flight — a stale ScreenCaptureKit list must never land on top of the
    /// tap's.
    private func apply(
        _ applications: [SourceApplication],
        unavailable: String?,
        builtFor backend: ThemCaptureBackend
    ) {
        guard backend == self.backend else { return }
        self.applications = applications
        self.unavailableReason = unavailable
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
