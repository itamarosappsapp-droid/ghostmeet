//
//  ChannelLevelProbe.swift
//  GhostMeet
//

import Accelerate
import Foundation
import os

/// Temporary instrumentation: is this capture delivering sound *right now*?
///
/// `CaptureDiagnostics` keeps a running peak, which answers a different
/// question — it cannot tell "was loud once at startup" from "is loud now", and
/// the whole of ADR-0005 is about a capture that keeps running while every
/// sample it hands over is zero. So this one is windowed, and it counts the
/// buffers that were *exactly* silent, which is the signature of that failure:
/// digital silence, right shape, no error anywhere.
///
/// Delete with `CaptureDiagnostics` — it is a probe, not a feature.
final class ChannelLevelProbe: @unchecked Sendable {

    private let log = Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
    private let label: String
    private let window: Int
    private let lock = NSLock()

    private var total = 0
    private var inWindow = 0
    private var windowPeak: Float = 0
    private var windowSilent = 0
    private var totalSilent = 0

    init(label: String, window: Int = 50) {
        self.label = label
        self.window = max(window, 1)
    }

    /// Records one delivered buffer. Cheap enough for the realtime thread: two
    /// vDSP passes over samples that are already in cache.
    func saw(samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))

        lock.lock()
        total += 1
        inWindow += 1
        windowPeak = max(windowPeak, rms)
        if peak == 0 {
            windowSilent += 1
            totalSilent += 1
        }
        let shouldLog = inWindow >= window
        let snapshot = (total, windowPeak, windowSilent, totalSilent, inWindow)
        if shouldLog {
            inWindow = 0
            windowPeak = 0
            windowSilent = 0
        }
        lock.unlock()

        guard shouldLog else { return }
        log.info("""
            УРОВЕНЬ метка=\(self.label, privacy: .public) \
            буферов=\(snapshot.0, privacy: .public) \
            окно=\(snapshot.4, privacy: .public) \
            пик_rms_окна=\(snapshot.1, privacy: .public) \
            тишины_в_окне=\(snapshot.2, privacy: .public) \
            тишины_всего=\(snapshot.3, privacy: .public) \
            частота=\(sampleRate, privacy: .public)
            """)
    }

    func saw(samples: [Float], sampleRate: Double) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            saw(samples: base, count: buffer.count, sampleRate: sampleRate)
        }
    }
}
