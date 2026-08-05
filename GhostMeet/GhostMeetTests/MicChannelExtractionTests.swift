import AVFoundation
import Testing
@testable import GhostMeet

/// Regression tests for a bug that cost a full debugging session because it made
/// no noise at all.
///
/// With voice processing on, the built-in microphone presents **seven** channels:
/// the processed mono stream plus the raw elements of the mic array. Handing that
/// buffer to `AVAudioConverter` and asking for mono makes it return silence — it
/// has no channel map for folding seven into one, and it reports no error. The
/// microphone indicator lights up, buffers keep arriving at the right rate, and
/// every single sample is zero.
@Suite("Многоканальный вход микрофона")
struct MicChannelExtractionTests {

    /// Builds a non-interleaved buffer where channel `i` is filled with `i + 1`,
    /// so the channel that survives extraction is identifiable by its value.
    /// Above two channels `AVAudioFormat` refuses to be built without an explicit
    /// layout — which is a hint of the same underlying fact that caused the bug:
    /// nothing in the audio stack knows how seven microphone channels fold into
    /// one, so nothing does it for you.
    private func buffer(channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels > 2 {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels
            )!
            format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: channels,
                interleaved: false
            )!
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let value = Float(channel + 1)
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = value
            }
        }
        return buffer
    }

    @Test("Микрофон отдал семь каналов — берём обработанный, а не тишину")
    func sevenChannelInputYieldsProcessedChannel() throws {
        let captured = buffer(channels: 7, frames: 512)

        let mono = try #require(MicCaptureService.firstChannel(of: captured))

        #expect(mono.format.channelCount == 1)
        #expect(mono.frameLength == 512)
        #expect(mono.format.sampleRate == captured.format.sampleRate)

        // Channel 0 carries 1.0 in the fixture: anything else means we picked the
        // wrong channel, and all zeros means we reproduced the original bug.
        let samples = UnsafeBufferPointer(start: mono.floatChannelData![0], count: 512)
        #expect(samples.allSatisfy { $0 == 1.0 })
    }

    @Test("Обычный одноканальный вход проходит насквозь без копирования")
    func monoInputPassesThrough() throws {
        let captured = buffer(channels: 1, frames: 256)

        let mono = try #require(MicCaptureService.firstChannel(of: captured))

        #expect(mono === captured)
    }

    @Test("Стереовход сводится к первому каналу")
    func stereoInputTakesFirstChannel() throws {
        let captured = buffer(channels: 2, frames: 128)

        let mono = try #require(MicCaptureService.firstChannel(of: captured))

        #expect(mono.format.channelCount == 1)
        let samples = UnsafeBufferPointer(start: mono.floatChannelData![0], count: 128)
        #expect(samples.allSatisfy { $0 == 1.0 })
    }

    @Test("Пустой буфер не порождает кадр")
    func emptyBufferProducesNothing() {
        let empty = buffer(channels: 7, frames: 512)
        empty.frameLength = 0

        #expect(MicCaptureService.firstChannel(of: empty) == nil)
    }
}
