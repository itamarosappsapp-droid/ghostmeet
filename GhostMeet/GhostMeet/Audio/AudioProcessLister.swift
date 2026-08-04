//
//  AudioProcessLister.swift
//  GhostMeet
//

import AppKit
import CoreAudio
import Darwin
import Foundation

/// Where the list of tappable applications comes from.
///
/// A protocol rather than a free function because everything above it — the
/// catalog the picker shows, and the recovery logic that re-finds a source
/// application after it was restarted — has to be exercised without a real
/// `coreaudiod` behind it.
nonisolated protocol AudioProcessLister: Sendable {
    /// Every process Core Audio currently knows about.
    func audioProcesses() -> [AudioProcess]
    /// Every application the system currently considers running.
    func runningApplications() -> [RunningApplication]
}

extension AudioProcessLister {

    /// The applications worth *offering* in the picker right now.
    func sourceApplications() -> [SourceApplication] {
        SourceApplication.offered(
            processes: audioProcesses(),
            applications: runningApplications()
        )
    }

    /// The chosen application as it exists right now, or `nil` if it is gone.
    ///
    /// Deliberately looks past the picker's filter. That filter hides anything
    /// that is neither a real application nor audible at this instant, and a
    /// process that has only just relaunched is exactly that: it registers with
    /// Core Audio a moment before it opens its output. Resolving through the
    /// filter would leave the tap waiting for a source that is already back.
    func resolveSourceApplication(id: String) -> SourceApplication? {
        SourceApplication
            .matching(processes: audioProcesses(), applications: runningApplications())
            .first { $0.id == id }
    }
}

/// The real thing: Core Audio's process object list, matched against the
/// applications the window server reports.
nonisolated final class CoreAudioProcessLister: AudioProcessLister {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    init() {}

    func audioProcesses() -> [AudioProcess] {
        Self.processObjectIDs().map { objectID in
            let pid = Self.value(pid_t.self, of: objectID, selector: kAudioProcessPropertyPID) ?? -1
            return AudioProcess(
                objectID: objectID,
                processIdentifier: pid,
                bundleIdentifier: Self.string(of: objectID, selector: kAudioProcessPropertyBundleID),
                executableURL: Self.executableURL(pid: pid),
                isPlayingAudio: Self.value(
                    UInt32.self,
                    of: objectID,
                    selector: kAudioProcessPropertyIsRunningOutput
                ).map { $0 != 0 } ?? false
            )
        }
    }

    func runningApplications() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications.map { application in
            RunningApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundleURL,
                localizedName: application.localizedName,
                isUserFacing: application.activationPolicy == .regular
            )
        }
    }

    // MARK: - Change notification

    /// Address of the property that changes whenever a process starts or stops
    /// using audio — the signal that a source application was quit or restarted.
    static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Calls `handler` whenever the process list changes. Returns the block that
    /// has to be handed back to `stopObservingProcessList` to unsubscribe.
    @discardableResult
    static func observeProcessList(
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = processListAddress
        AudioObjectAddPropertyListenerBlock(systemObject, &address, queue, block)
        return block
    }

    static func stopObservingProcessList(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        on queue: DispatchQueue
    ) {
        var address = processListAddress
        AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, block)
    }

    // MARK: - Core Audio plumbing

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func value<Value>(
        _ type: Value.Type,
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr else {
            return nil
        }
        return storage.pointee
    }

    private static func string(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = value as String?, !value.isEmpty else { return nil }
        return value
    }

    /// Path of the binary behind a PID.
    ///
    /// It is the only way to tell a browser helper from an unrelated process
    /// with the same-looking bundle identifier, and the only handle at all on
    /// processes that have no bundle identifier — a plain command-line player,
    /// for instance.
    private static func executableURL(pid: pid_t) -> URL? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
