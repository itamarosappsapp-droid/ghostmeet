//
//  PCMMixdown.swift
//  GhostMeet
//

// AVFAudio has not been audited for concurrency: buffers travel from the
// realtime capture thread by design, and the SDK does not say so in types yet.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Folding a raw `AudioBufferList` into one mono buffer we own.
///
/// Shared by both `Them` backends because both walk into the same trap: on this
/// platform the format a capture *reports* and the layout it actually
/// *delivers* do not have to agree, and when they disagree nothing says so.
/// `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` refuses a mismatched list by
/// returning nil, silently, so every frame disappears while the capture callback
/// runs perfectly and no return code anywhere is non-zero.
///
/// So the layout is read off the buffer list itself — `mNumberBuffers` is the
/// only honest witness — and the samples are copied out by hand. It costs one
/// pass per callback and it cannot quietly produce nothing.
nonisolated enum PCMMixdown {

    /// Averages every channel of `list` into a single mono buffer.
    ///
    /// Channels are averaged rather than picked: this is a mixdown of a call,
    /// and dropping one side would drop whoever is panned into it.
    ///
    /// - Parameters:
    ///   - list: buffer list as the capture callback handed it over.
    ///   - sampleRate: rate of the samples in it. Not derivable from the list,
    ///     so the caller has to know it.
    static func mono(
        from list: UnsafePointer<AudioBufferList>,
        sampleRate: Double
    ) -> AVAudioPCMBuffer? {
        // `UnsafeMutableAudioBufferListPointer` and not a hand-rolled
        // `UnsafeBufferPointer` over `mBuffers`: an `AudioBufferList` is a
        // variable-length structure, and taking the address of its `mBuffers`
        // field through Swift yields a pointer to a *copy* of the first element.
        // Reading past index 0 through that copy walks off the stack — which is
        // exactly the planar case, the one that carries the other side's voice.
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return nil }

        // More than one buffer means one buffer per channel (planar); a single
        // buffer means the channels are interleaved inside it.
        let planar = buffers.count > 1
        let channelsInFirst = Int(first.mNumberChannels)
        let stride = planar ? 1 : max(channelsInFirst, 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
        guard frames > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
           let destination = mono.floatChannelData else { return nil }

        mono.frameLength = AVAudioFrameCount(frames)
        let out = destination[0]

        if planar {
            let sources = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard !sources.isEmpty else { return nil }
            let scale = 1 / Float(sources.count)
            for frame in 0..<frames {
                var sum: Float = 0
                for source in sources { sum += source[frame] }
                out[frame] = sum * scale
            }
        } else {
            guard let source = first.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let scale = 1 / Float(stride)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<stride { sum += source[frame * stride + channel] }
                out[frame] = sum * scale
            }
        }
        return mono
    }
}
