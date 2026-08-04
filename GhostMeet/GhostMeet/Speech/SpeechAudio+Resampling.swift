//
//  SpeechAudio+Resampling.swift
//  GhostMeet
//

import Foundation

nonisolated extension SpeechAudio {
    /// The same audio at the rate the model needs.
    ///
    /// The microphone backend already delivers 16 kHz, so in the normal case this
    /// hands the samples straight back. It exists for the capture backends that
    /// do not get to choose their rate — a process tap reports whatever the
    /// source application runs at — so that the choice of rate stays a property
    /// of capture and never leaks into recognition.
    ///
    /// Linear interpolation is enough here: speech is band-limited well below
    /// 8 kHz and Whisper's own feature extractor low-passes it again.
    func resampled(to targetRate: Double) -> [Float] {
        guard sampleRate > 0, targetRate > 0, !samples.isEmpty else { return [] }
        guard abs(sampleRate - targetRate) > 0.5 else { return samples }

        let ratio = sampleRate / targetRate
        let outputCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outputCount > 0 else { return [] }

        var output = [Float]()
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * ratio
            let lower = Int(position)
            let upper = min(lower + 1, samples.count - 1)
            let weight = Float(position - Double(lower))
            output.append(samples[lower] * (1 - weight) + samples[upper] * weight)
        }
        return output
    }
}
