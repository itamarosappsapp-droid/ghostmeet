//
//  AudioRouteMonitor.swift
//  GhostMeet
//

import CoreAudio
import Foundation

/// Both ends of the route as read at one instant. Either may be missing: a
/// machine can have no default input, and Core Audio says so by returning
/// nothing rather than by failing.
nonisolated struct AudioRouteSnapshot: Equatable, Sendable {
    let input: AudioEndpoint?
    let output: AudioEndpoint?

    static let empty = AudioRouteSnapshot(input: nil, output: nil)
}

/// Where the route comes from.
///
/// A seam for the same reason capture and speech have one (ADR-0001): the rule
/// «route changed → everybody who cares is told» has to be checkable on a machine
/// with no sound hardware at all, and Core Audio cannot be asked to pretend that
/// headphones were just plugged in.
nonisolated protocol AudioRouteSource: AnyObject, Sendable {
    func read() -> AudioRouteSnapshot
    /// Starts calling `onChange` whenever the route may have changed. The
    /// callback is a hint, not a value: the monitor re-reads for itself.
    func startObserving(_ onChange: @escaping @Sendable () -> Void)
    func stopObserving()
}

/// Knows which way the sound goes right now, and keeps knowing it.
///
/// **Cached on purpose.** `SessionEngine.isLeakyRoute` is read on every `You`
/// frame — dozens of times a second — and asking Core Audio that often would put
/// a device round trip on the audio path. So the verdict is computed when it
/// changes and read from memory in between.
///
/// **Subscribed on purpose.** The route changes mid-call: headphones go in
/// halfway through a question, a headset drops its connection, another
/// application takes the default device. A value sampled when the session started
/// would be a lie by the second question — which is exactly why the seam it feeds
/// is a closure rather than a `Bool`.
nonisolated final class AudioRouteMonitor: @unchecked Sendable {

    private let source: any AudioRouteSource
    private let lock = NSLock()
    private var current: AudioRoute = .unread
    private var subscriber: (@Sendable (AudioRoute) -> Void)?

    init(source: any AudioRouteSource = CoreAudioRouteSource()) {
        self.source = source
    }

    deinit {
        source.stopObserving()
    }

    /// The route as last read. Cheap — this is what the per-frame seam calls.
    var route: AudioRoute {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The one thing the audio layer asks: may the microphone be carrying the
    /// other side's voice?
    var mayLeak: Bool { route.mayLeak }

    /// Who to tell when the verdict changes. Set before `start()`.
    func onChange(_ subscriber: @escaping @Sendable (AudioRoute) -> Void) {
        lock.lock()
        self.subscriber = subscriber
        lock.unlock()
    }

    /// Reads the route once and starts following it.
    ///
    /// Reading first and subscribing after would leave a gap in which a change is
    /// missed; the other order can only ever cost one redundant read.
    func start() {
        source.startObserving { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        source.stopObserving()
    }

    /// Re-reads the route and, if the verdict is new, says so.
    ///
    /// Only a *changed* verdict is published. A single switch of the default
    /// device produces a burst of property notifications — the same burst
    /// `CaptureRecovery` folds — and republishing the same route three times
    /// would redraw the window three times and write three identical lines into
    /// the log.
    func refresh() {
        let snapshot = source.read()
        let route = AudioRoute.classify(input: snapshot.input, output: snapshot.output)
        lock.lock()
        let changed = route != current
        current = route
        let subscriber = self.subscriber
        lock.unlock()
        if changed { subscriber?(route) }
    }
}

/// The real thing: Core Audio's default devices and the notifications they post.
///
/// Read-only from start to finish. It never sets a default device, never opens a
/// stream and never touches a data source — a route classifier that changed the
/// route would be its own worst bug.
nonisolated final class CoreAudioRouteSource: AudioRouteSource, @unchecked Sendable {

    /// All listener work happens here, so the registered blocks and the handler
    /// need no lock of their own.
    private let queue = DispatchQueue(label: "Mixxy.GhostMeet.audio-route")

    /// What has been registered, so it can be taken back down. Device-scoped
    /// listeners are re-registered on every change, because the device they were
    /// attached to may be the one that went away.
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var handler: (@Sendable () -> Void)?

    init() {}

    deinit {
        // Synchronously, and with the very queue the block was registered on:
        // Core Audio matches a listener by the pair (block, queue), so removing
        // it with `nil` would leave it hanging on a deallocated object.
        for (id, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
    }

    // MARK: - Reading

    func read() -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            input: Self.endpoint(
                of: Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                scope: kAudioDevicePropertyScopeInput
            ),
            output: Self.endpoint(
                of: Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                scope: kAudioDevicePropertyScopeOutput
            )
        )
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func endpoint(
        of id: AudioDeviceID?,
        scope: AudioObjectPropertyScope
    ) -> AudioEndpoint? {
        guard let id else { return nil }
        return AudioEndpoint(
            name: string(id, kAudioObjectPropertyName) ?? "—",
            transport: fourCC(u32(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)) ?? "",
            dataSource: fourCC(u32(id, kAudioDevicePropertyDataSource, scope))
        )
    }

    private static func string(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func u32(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    /// Turns a four-character code into the string the classifier compares.
    private static func fourCC(_ value: UInt32?) -> String? {
        guard let value else { return nil }
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)
    }

    // MARK: - Following

    func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            unregisterAll()
            handler = onChange
            // The default device changing is the obvious half.
            listen(to: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
            listen(to: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal)
            listenToDataSources()
        }
    }

    func stopObserving() {
        queue.async { [self] in
            handler = nil
            unregisterAll()
        }
    }

    /// The non-obvious half: on Macs with a headphone jack, plugging headphones
    /// in does not change the default *device* — it changes the built-in output's
    /// data source from `ispk` to `hdpn`. Without this the classifier would go on
    /// reporting speakers for the whole call.
    ///
    /// Re-registered after every change, because the device these hang on is the
    /// one that may have just been unplugged.
    private func listenToDataSources() {
        if let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            listen(to: output, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)
        }
        if let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) {
            listen(to: input, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeInput)
        }
    }

    private func listen(
        to id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            queue.async {
                // The device-scoped listeners are rehung first: by the time the
                // subscriber re-reads, they must already point at whatever is
                // the default now.
                self.rehangDataSourceListeners()
                self.handler?()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr else { return }
        registrations.append((id, address, block))
    }

    private func rehangDataSourceListeners() {
        let survivors = registrations.filter { $0.1.mSelector != kAudioDevicePropertyDataSource }
        for registration in registrations where registration.1.mSelector == kAudioDevicePropertyDataSource {
            var address = registration.1
            AudioObjectRemovePropertyListenerBlock(registration.0, &address, queue, registration.2)
        }
        registrations = survivors
        listenToDataSources()
    }

    private func unregisterAll() {
        for (id, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        registrations = []
    }
}
