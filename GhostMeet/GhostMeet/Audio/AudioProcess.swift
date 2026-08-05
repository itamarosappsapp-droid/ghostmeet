//
//  AudioProcess.swift
//  GhostMeet
//

import CoreAudio
import Foundation

/// One process as Core Audio sees it.
///
/// Core Audio hands out processes, not applications, and the two do not line up:
/// a browser plays its sound from a helper process with its own PID and its own
/// bundle identifier, while the main process stays silent. Everything above this
/// type works with applications, so this is the last place where a raw process
/// is visible.
nonisolated struct AudioProcess: Identifiable, Hashable, Sendable {
    var id: AudioObjectID { objectID }

    /// The object as `coreaudiod` knows it. Assigned by the system and reused —
    /// never store it as identity, it does not survive a restart of the process.
    let objectID: AudioObjectID
    let processIdentifier: pid_t
    /// Bundle identifier of the process itself, which for a helper is its own
    /// (`com.google.Chrome.helper`), not the browser's.
    let bundleIdentifier: String?
    let executableURL: URL?
    /// Whether the process is sending audio to a device right now.
    let isPlayingAudio: Bool

    init(
        objectID: AudioObjectID,
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        executableURL: URL? = nil,
        isPlayingAudio: Bool = false
    ) {
        self.objectID = objectID
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier?.isEmpty == true ? nil : bundleIdentifier
        self.executableURL = executableURL
        self.isPlayingAudio = isPlayingAudio
    }
}

/// An application as the system knows it — only the parts needed to recognise
/// which audio processes belong to it and to show it to the user by name.
nonisolated struct RunningApplication: Hashable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
    let localizedName: String?
    /// Whether the application has a Dock icon and a user interface. Background
    /// agents and daemons are running applications too, and putting them in the
    /// picker would bury the browser in noise.
    let isUserFacing: Bool

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        bundleURL: URL? = nil,
        localizedName: String? = nil,
        isUserFacing: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier?.isEmpty == true ? nil : bundleIdentifier
        self.bundleURL = bundleURL
        self.localizedName = localizedName
        self.isUserFacing = isUserFacing
    }

    /// Identity that survives a restart of the application: the bundle
    /// identifier if there is one, its location on disk otherwise. Deliberately
    /// not the PID — the whole point is to find the application again after it
    /// has been quit and reopened.
    var identity: String {
        bundleIdentifier ?? bundleURL?.path ?? "pid:\(processIdentifier)"
    }

    var displayName: String {
        localizedName
            ?? bundleURL?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier
            ?? "PID \(processIdentifier)"
    }
}

/// The «приложение-источник» as the user picks it: one whole application, with
/// every audio process it runs gathered behind it.
///
/// Granularity is the application and nothing finer. A browser tab cannot be
/// separated from the rest of the browser by any capture API, so anything else
/// playing in the same application lands in `Them` as well — the interface must
/// not promise otherwise.
nonisolated struct SourceApplication: Identifiable, Hashable, Sendable {
    /// Stable across restarts of the application, which is what makes recovery
    /// possible: the process objects behind it are re-resolved by this id.
    let id: String
    let name: String
    /// Every Core Audio process object of this application — the main process
    /// and its helpers together, because which of them carries the sound is not
    /// something the user should have to know.
    let processObjectIDs: [AudioObjectID]
    /// Whether any of those processes is producing sound at this moment.
    let isPlayingAudio: Bool
    /// Whether this entry is a real application rather than a bare process that
    /// happened to open an audio device.
    let isUserFacing: Bool

    init(
        id: String,
        name: String,
        processObjectIDs: [AudioObjectID],
        isPlayingAudio: Bool = false,
        isUserFacing: Bool = true
    ) {
        self.id = id
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.isPlayingAudio = isPlayingAudio
        self.isUserFacing = isUserFacing
    }
}

extension SourceApplication {

    /// Folds a flat list of audio processes into the applications behind them.
    ///
    /// This is the whole answer to «the browser plays its sound from a helper
    /// process»: the helper is matched to the browser and disappears into it, so
    /// the user picks *Google Chrome* and the tap gets every process the browser
    /// runs, whichever one turns out to be making noise.
    ///
    /// Matching goes from certain to plausible, and an earlier rule wins, so a
    /// separate application never gets swallowed by a prefix of its bundle
    /// identifier.
    static func matching(
        processes: [AudioProcess],
        applications: [RunningApplication]
    ) -> [SourceApplication] {
        var byIdentity: [String: SourceApplication] = [:]
        var order: [String] = []

        for process in processes {
            let owner = applications.first { $0.owns(process) }
            let identity = owner?.identity ?? process.fallbackIdentity
            let name = owner?.displayName ?? process.fallbackName
            let isUserFacing = owner?.isUserFacing ?? false

            if let existing = byIdentity[identity] {
                byIdentity[identity] = SourceApplication(
                    id: identity,
                    name: existing.name,
                    processObjectIDs: existing.processObjectIDs + [process.objectID],
                    isPlayingAudio: existing.isPlayingAudio || process.isPlayingAudio,
                    isUserFacing: existing.isUserFacing || isUserFacing
                )
            } else {
                order.append(identity)
                byIdentity[identity] = SourceApplication(
                    id: identity,
                    name: name,
                    processObjectIDs: [process.objectID],
                    isPlayingAudio: process.isPlayingAudio,
                    isUserFacing: isUserFacing
                )
            }
        }

        return order.compactMap { byIdentity[$0] }
    }

    /// The list the picker shows: real applications, plus whatever else is
    /// making sound right now.
    ///
    /// Both halves are needed. An application has to be selectable while it is
    /// still silent — the browser is picked before the call starts — and a bare
    /// process that is audible right now is exactly what the user is looking for
    /// when it is not one.
    static func offered(
        processes: [AudioProcess],
        applications: [RunningApplication]
    ) -> [SourceApplication] {
        inOfferOrder(matching(processes: processes, applications: applications))
    }

    /// The list the picker shows while **ScreenCaptureKit** is the backend.
    ///
    /// A different list, not a filtered one. `SCShareableContent` knows every
    /// application that owns a window and knows nothing of a command-line
    /// player; Core Audio knows the exact opposite. Keeping the tap's list under
    /// this backend would let the user pick something `SCStream` cannot see, and
    /// the channel would then go quiet with nothing on screen to explain why.
    ///
    /// `audioProcesses` is still read from Core Audio, and only to answer «is it
    /// making noise right now»: that is a fact about the machine rather than
    /// about the backend, and the «звучит» marker is the one hint that tells the
    /// user which of five browsers is carrying the call.
    static func offered(
        shareable: [ShareableApplication],
        applications: [RunningApplication],
        audioProcesses: [AudioProcess] = [],
        excluding excludedProcess: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> [SourceApplication] {
        let audible = Set(
            matching(processes: audioProcesses, applications: applications)
                .filter(\.isPlayingAudio)
                .map(\.id)
        )

        var byIdentity: [String: SourceApplication] = [:]
        var order: [String] = []

        for entry in shareable where entry.processIdentifier != excludedProcess {
            let owner = applications.first { $0.owns(entry) }
            let identity = owner?.identity ?? entry.fallbackIdentity
            // An entry ScreenCaptureKit offers owns a window by definition, so
            // «not a real application» can only come from the running-application
            // list saying so — the Dock, Control Centre, our own overlay.
            let isUserFacing = owner?.isUserFacing ?? true

            if let existing = byIdentity[identity] {
                byIdentity[identity] = SourceApplication(
                    id: identity,
                    name: existing.name,
                    processObjectIDs: existing.processObjectIDs,
                    isPlayingAudio: existing.isPlayingAudio,
                    isUserFacing: existing.isUserFacing || isUserFacing
                )
            } else {
                order.append(identity)
                byIdentity[identity] = SourceApplication(
                    id: identity,
                    name: owner?.displayName ?? entry.displayName,
                    // Empty on purpose: `SCStream` is pointed at PIDs, never at
                    // Core Audio objects, and filling these in would be a claim
                    // the capture side would afterwards have to work around.
                    processObjectIDs: [],
                    isPlayingAudio: audible.contains(identity),
                    isUserFacing: isUserFacing
                )
            }
        }

        return inOfferOrder(order.compactMap { byIdentity[$0] })
    }

    /// Whatever is making sound first, then by name. Shared by both backends so
    /// that switching one for the other does not reshuffle the picker.
    private static func inOfferOrder(_ applications: [SourceApplication]) -> [SourceApplication] {
        applications
            .filter { $0.isUserFacing || $0.isPlayingAudio }
            .sorted { left, right in
                if left.isPlayingAudio != right.isPlayingAudio { return left.isPlayingAudio }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}

extension RunningApplication {

    /// Whether this application is the one behind the given audio process.
    func owns(_ process: AudioProcess) -> Bool {
        owns(
            processIdentifier: process.processIdentifier,
            bundleIdentifier: process.bundleIdentifier,
            executableURL: process.executableURL
        )
    }

    /// Whether this application is the one behind the application
    /// ScreenCaptureKit is offering.
    ///
    /// Same rule, other list: `SCShareableContent` reports helpers as separate
    /// applications too, and folding them into the browser here is what keeps
    /// the picker showing one Chrome under either backend.
    func owns(_ application: ShareableApplication) -> Bool {
        owns(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            executableURL: application.executableURL
        )
    }

    /// The rule itself, over the three fields both capture backends describe a
    /// process with. Kept as one predicate rather than a chain of passes because
    /// the rules do not conflict: a helper matches its own application by all
    /// three at once, and an unrelated process by none.
    private func owns(
        processIdentifier pid: pid_t,
        bundleIdentifier processBundleID: String?,
        executableURL: URL?
    ) -> Bool {
        if pid == processIdentifier { return true }
        if let mine = bundleIdentifier, let theirs = processBundleID {
            // `com.google.Chrome` owns `com.google.Chrome.helper`, and the dot
            // is what keeps it from also owning `com.google.ChromeCanary`.
            if theirs == mine || theirs.hasPrefix(mine + ".") { return true }
        }
        if let bundleURL, let executableURL,
           executableURL.path.hasPrefix(bundleURL.path + "/") {
            return true
        }
        return false
    }
}

extension AudioProcess {

    /// Identity for a process that belongs to no running application.
    ///
    /// The outermost `.app` on its path comes first: a helper whose application
    /// is not in the running list still groups under that application rather
    /// than turning into several separate entries.
    var fallbackIdentity: String {
        if let bundle = executableURL?.enclosingApplicationBundle { return bundle.path }
        if let bundleIdentifier { return bundleIdentifier }
        if let executableURL { return executableURL.path }
        return "audio-process:\(objectID)"
    }

    var fallbackName: String {
        if let bundle = executableURL?.enclosingApplicationBundle {
            return bundle.deletingPathExtension().lastPathComponent
        }
        if let executableURL { return executableURL.lastPathComponent }
        if let bundleIdentifier { return bundleIdentifier }
        return "PID \(processIdentifier)"
    }
}

extension URL {

    /// The outermost `.app` this executable lives in, if any.
    ///
    /// Outermost rather than nearest on purpose: a browser helper sits in
    /// `Google Chrome.app/…/Google Chrome Helper.app/…`, and the entry the user
    /// is looking for is the browser, not the helper.
    var enclosingApplicationBundle: URL? {
        let components = pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: "/" + components[1...index].joined(separator: "/"))
    }
}
