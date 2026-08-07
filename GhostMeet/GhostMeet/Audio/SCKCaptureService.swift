//
//  SCKCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The `Them` channel taken with ScreenCaptureKit — the second capture backend
/// of ADR-0001.
///
/// It was built when the tap and microphone echo cancellation were believed to
/// be incompatible (ADR-0005); they are not (ADR-0007), and echo cancellation is
/// gone from the app altogether (ADR-0009). What kept this backend is a
/// measurement rather than that story: on one and the same recording `SCStream`
/// delivers 1.5–2.5× more signal than the tap, and loudness is what recognition
/// quality hangs on — which is why it is the default (ADR-0006).
///
/// Everything else matches `ProcessTapCaptureService` on purpose: the same
/// stable-id resolution, the same statuses, the same 16 kHz mono frames, so that
/// swapping one for the other changes nothing above the seam.
nonisolated final class SCKCaptureService: ThemAudioSource, @unchecked Sendable {

    let channel: Channel = .them

    /// Called whenever the status changes, on an arbitrary thread.
    var onStatusChange: (@Sendable (ThemCaptureStatus) -> Void)?

    private let stream: any ThemAudioStream
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.ghostmeet.sck.changes")

    private var _isRunning = false
    private var _status: ThemCaptureStatus = .idle
    private var _sourceApplicationID: String?
    private var onFrame: AudioFrameHandler?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var lastKnownName: String?
    private var attachTask: Task<Void, Never>?
    private var listener: AudioObjectPropertyListenerBlock?

    /// - Parameters:
    ///   - sourceApplicationID: stable id of the chosen application, or `nil`
    ///     while the user has not chosen one.
    ///   - sampleRate: rate the frames are delivered at. The same 16 kHz mono the
    ///     microphone produces, so that recognition sees one shape of audio and
    ///     not two.
    init(
        sourceApplicationID: String? = nil,
        stream: any ThemAudioStream = SCKAudioStream(),
        sampleRate: Double = 16_000
    ) {
        self._sourceApplicationID = sourceApplicationID
        self.stream = stream
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        stream.onFailure = { [weak self] error in
            self?.publish(.failed(reason: error.localizedDescription))
        }
    }

    deinit { stream.stop() }

    // MARK: - State

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var status: ThemCaptureStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var sourceApplicationID: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _sourceApplicationID
        }
        set {
            lock.lock()
            let changed = _sourceApplicationID != newValue
            _sourceApplicationID = newValue
            if changed { lastKnownName = nil }
            let running = _isRunning
            lock.unlock()

            guard changed, running else { return }
            scheduleAttach()
        }
    }

    // MARK: - AudioSource

    /// Starts listening to the chosen application.
    ///
    /// Like the process-tap backend, it does not throw for the two ordinary
    /// cases — nothing chosen yet, and the chosen application not being on
    /// offer. A session with a working microphone must not refuse to start
    /// because the browser is closed; both land in `status` instead.
    func start(onFrame: @escaping AudioFrameHandler) throws {
        lock.lock()
        guard !_isRunning else { lock.unlock(); return }
        self.onFrame = onFrame
        _isRunning = true
        lock.unlock()

        startObservingProcessList()
        scheduleAttach()
    }

    func stop() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        onFrame = nil
        let task = attachTask
        attachTask = nil
        converter = nil
        sourceFormat = nil
        lock.unlock()

        task?.cancel()
        stopObservingProcessList()
        stream.stop()
        publish(.idle)
    }

    /// Waits for the attach that is already in flight.
    ///
    /// ScreenCaptureKit is asynchronous all the way down — resolving the content
    /// and starting the stream are both `await` — so whoever needs to know how it
    /// ended has to be able to wait for it instead of sleeping. Mirrors
    /// `SessionController.waitForStart()`.
    func waitForAttach() async {
        lock.lock()
        let task = attachTask
        lock.unlock()
        await task?.value
    }

    // MARK: - Stream lifecycle

    /// Attaches after whatever attach is already running has finished.
    ///
    /// Serialised rather than cancelled-and-restarted: the source can be
    /// re-pointed twice in a row while the first resolution is still in flight,
    /// and two `SCStream`s starting over each other leave one of them orphaned.
    private func scheduleAttach() {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        let previous = attachTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.attachNow()
        }
        attachTask = task
        lock.unlock()
    }

    private func attachNow() async {
        lock.lock()
        let id = _sourceApplicationID
        let handler = onFrame
        let running = _isRunning
        lock.unlock()

        guard running, let handler else { return }
        stream.stop()

        guard let id, !id.isEmpty else {
            publish(.idle)
            return
        }

        do {
            let matching = try await stream.shareableApplications()
                .filter { $0.matches(sourceApplicationID: id) }

            guard !matching.isEmpty else {
                lock.lock()
                let remembered = lastKnownName ?? id
                lock.unlock()
                publish(.waitingForSource(application: remembered))
                return
            }

            let scope = SCKAudioScope.applications(Set(matching.map(\.processIdentifier)))
            // The application itself names the entry, not one of its helpers: the
            // user picked «Google Chrome», not «Google Chrome Helper (Renderer)».
            let name = matching.first { $0.bundleIdentifier == id }?.displayName
                ?? matching[0].displayName
            lock.lock()
            lastKnownName = name
            lock.unlock()

            try await stream.start(scope: scope) { [weak self] buffer in
                guard let self, let frame = self.makeFrame(from: buffer) else { return }
                handler(frame)
            }
            publish(.capturing(application: name))
        } catch {
            publish(.failed(reason: error.localizedDescription))
        }
    }

    private func publish(_ status: ThemCaptureStatus) {
        lock.lock()
        let changed = _status != status
        _status = status
        let handler = onStatusChange
        lock.unlock()
        if changed { handler?(status) }
    }

    // MARK: - Recovery from a restart of the source application

    /// ScreenCaptureKit has no "the applications changed" notification, but Core
    /// Audio's process list moves whenever anything starts or stops using audio,
    /// which is the same event from a different angle: the browser was quit,
    /// restarted, or has just woken its audio helper up.
    private func startObservingProcessList() {
        let block = CoreAudioProcessLister.observeProcessList(on: listenerQueue) { [weak self] in
            self?.scheduleAttach()
        }
        lock.lock()
        listener = block
        lock.unlock()
    }

    private func stopObservingProcessList() {
        lock.lock()
        let block = listener
        listener = nil
        lock.unlock()
        guard let block else { return }
        CoreAudioProcessLister.stopObservingProcessList(block, on: listenerQueue)
    }

    // MARK: - Format

    /// Downmixes and resamples one captured buffer into a `Them` frame.
    ///
    /// ScreenCaptureKit delivers 48 kHz stereo while recognition wants 16 kHz
    /// mono. The conversion lives here so the choice of rate stays a property of
    /// capture and never leaks into `Speech`.
    private func makeFrame(from buffer: AVAudioPCMBuffer) -> AudioFrame? {
        guard buffer.frameLength > 0 else { return nil }

        lock.lock()
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            sourceFormat = buffer.format
        }
        let converter = converter
        lock.unlock()
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var alreadyFed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if alreadyFed {
                status.pointee = .noDataNow
                return nil
            }
            alreadyFed = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              output.frameLength > 0,
              let channelData = output.floatChannelData?[0] else { return nil }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(output.frameLength)))
        return AudioFrame(channel: .them, samples: samples, sampleRate: targetFormat.sampleRate)
    }
}
