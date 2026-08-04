//
//  AudioSource.swift
//  GhostMeet
//

import Accelerate
import Foundation

/// A chunk of mono PCM produced by an `AudioSource`, already tagged with its channel.
///
/// The tag comes from the source, never from the content of the speech.
nonisolated struct AudioFrame: Sendable, Equatable {
    /// Channel this audio belongs to.
    let channel: Channel
    /// Mono samples, nominally in the -1...1 range.
    let samples: [Float]
    let sampleRate: Double

    init(channel: Channel, samples: [Float], sampleRate: Double) {
        self.channel = channel
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// How much wall time this frame covers.
    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    /// Loudness of the frame. Compared against the silence gate to tell speech
    /// from a quiet room, so that silence never opens a turn and never reaches
    /// recognition.
    var rms: Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
}

/// Where a source hands captured audio over.
///
/// May be called on a realtime audio thread: the consumer is responsible for
/// hopping to its own isolation. `SessionEngine` hops to the main actor itself,
/// so implementations must not do it for it.
typealias AudioFrameHandler = @Sendable (AudioFrame) -> Void

/// One capture backend feeding exactly one channel.
///
/// `SessionEngine` sees nothing but this protocol: it never learns whether the
/// frames arrive from the microphone, from a Core Audio process tap or from a
/// test (ADR-0001). Adding the `Them` channel therefore means adding an
/// implementation, not touching the engine.
nonisolated protocol AudioSource: AnyObject {
    /// Channel every frame of this source belongs to.
    var channel: Channel { get }
    /// Whether capture is currently running.
    var isRunning: Bool { get }
    /// Starts capture. Frames keep arriving through `onFrame` until `stop()`.
    func start(onFrame: @escaping AudioFrameHandler) throws
    func stop()
}
