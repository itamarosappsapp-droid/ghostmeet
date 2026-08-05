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
/// Voice processing (VPIO) is the defence against channel leak — `Them` coming
/// out of the speakers and being caught by the microphone. It is **not** always
/// on, because it cannot be: enabling it silences the process tap that feeds the
/// `Them` channel (see ADR-0005). Whoever builds this service decides, and the
/// rule is in `SessionController.dualChannel`.
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

    /// Whether echo cancellation is switched on for this capture.
    ///
    /// Off while the `Them` channel is tapping an application: VPIO takes over
    /// the machine's audio path and hands the tap pure silence. With it off the
    /// user needs headphones, or their own channel collects the other side's
    /// voice (ADR-0005).
    private let voiceProcessingEnabled: Bool

    /// Holds the converter for whatever format the tap turns out to deliver.
    ///
    /// Built on the first buffer instead of up front: the format a voice-processed
    /// input node reports and the one it delivers are not always the same, and the
    /// buffer is the only source of truth. Rebuilt if the format ever changes
    /// under us — switching the input device mid-call does that.
    private final class ConverterBox: @unchecked Sendable {
        private var converter: AVAudioConverter?
        private var sourceFormat: AVAudioFormat?

        func converter(for source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
            if let converter, sourceFormat == source { return converter }
            guard let made = AVAudioConverter(from: source, to: target) else { return nil }
            converter = made
            sourceFormat = source
            return made
        }
    }

    /// - Parameter sampleRate: rate the frames are delivered at. 16 kHz mono is
    ///   what speech recognition wants, and it keeps the buffers small.
    init(sampleRate: Double = 16_000, voiceProcessing: Bool = true) {
        voiceProcessingEnabled = voiceProcessing
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
        if voiceProcessingEnabled {
            do {
                // Enabling voice processing changes the node's format, so it must
                // happen before the format is read and before the tap is installed.
                try input.setVoiceProcessingEnabled(true)
            } catch {
                throw CaptureError.voiceProcessingUnavailable(error)
            }

            // Voice processing ducks every other sound on the machine while it
            // captures. That is wrong here twice over: it quietens the call the
            // user is listening to, and it quietens the very audio the `Them`
            // channel is trying to recognise. Ducking is turned down to its
            // minimum; echo cancellation itself is unaffected.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.inputFormatUnavailable
        }

        // The tap is installed with `nil` rather than with the format the node
        // reports. With voice processing on, the reported format and the one the
        // node actually delivers can differ, and a tap pinned to the wrong one
        // yields buffers of digital silence — the microphone indicator lights up
        // and every sample is zero. `nil` means "whatever this node really
        // produces", which is also why the converter below is built from the
        // buffer rather than from the reported format.
        let targetFormat = targetFormat
        let converterBox = ConverterBox()
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard let mono = Self.firstChannel(of: buffer) else { return }
            guard let converter = converterBox.converter(for: mono.format, to: targetFormat) else {
                return
            }
            guard let frame = Self.makeFrame(
                from: mono,
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
            throw error
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Takes channel 0 of a captured buffer as a mono buffer at the same rate.
    ///
    /// This exists because of a trap that costs a whole debugging session if you
    /// meet it blind: with voice processing on, the built-in microphone presents
    /// **seven** channels — the processed mono stream plus the raw elements of
    /// the mic array. Handing that straight to `AVAudioConverter` and asking for
    /// mono makes it return **silence**: it has no channel map for folding seven
    /// into one, and it reports no error while doing so. The indicator lights up,
    /// buffers keep arriving, and every sample is zero.
    ///
    /// Channel 0 is the stream voice processing has already cleaned, which is
    /// exactly the one the `You` channel wants.
    /// Internal rather than private so the regression test can reach it.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        guard buffer.frameLength > 0, !format.isInterleaved, let source = buffer.floatChannelData else {
            return nil
        }
        guard format.channelCount > 1 else { return buffer }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
           let destination = mono.floatChannelData else {
            return nil
        }

        mono.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return mono
    }

    /// Resamples one captured buffer into a `You` frame.
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
