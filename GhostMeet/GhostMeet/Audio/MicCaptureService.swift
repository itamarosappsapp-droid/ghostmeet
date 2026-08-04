//
//  MicCaptureService.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: its buffers travel from the
// realtime capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import Foundation

/// Microphone capture: the source of the `You` channel.
///
/// Voice processing (VPIO) is switched on for the input node before the engine
/// starts. It is the only defence against channel leak — `Them` coming out of
/// the speakers and being caught by the microphone — and it has to work with the
/// headphones off, which is the normal case for the user.
nonisolated final class MicCaptureService: AudioSource, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case voiceProcessingUnavailable(Error)
        case inputFormatUnavailable
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .voiceProcessingUnavailable:
                // Without VPIO the user's channel would collect the other side's
                // voice, so capture refuses to start rather than leak.
                return "Не удалось включить подавление эха на микрофоне"
            case .inputFormatUnavailable:
                return "Микрофон не сообщил формат записи"
            case .converterUnavailable:
                return "Не удалось подготовить преобразование звука микрофона"
            }
        }
    }

    let channel: Channel = .you
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    /// - Parameter sampleRate: rate the frames are delivered at. 16 kHz mono is
    ///   what speech recognition wants, and it keeps the buffers small.
    init(sampleRate: Double = 16_000) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    /// Asks the system for microphone access, if it has not been decided yet.
    ///
    /// Returns whether capture is allowed. A refusal has to be shown inside the
    /// app window: system banners would show up on top of a shared screen.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start(onFrame: @escaping AudioFrameHandler) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        do {
            // Enabling voice processing changes the node's format, so it must
            // happen before the format is read and before the tap is installed.
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw CaptureError.voiceProcessingUnavailable(error)
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.inputFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        let targetFormat = targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let frame = Self.makeFrame(
                from: buffer,
                converter: converter,
                targetFormat: targetFormat
            ) else { return }
            onFrame(frame)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    /// Downmixes and resamples one captured buffer into a `You` frame.
    private static func makeFrame(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AudioFrame? {
        guard buffer.frameLength > 0 else { return nil }
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
        return AudioFrame(channel: .you, samples: samples, sampleRate: targetFormat.sampleRate)
    }
}
