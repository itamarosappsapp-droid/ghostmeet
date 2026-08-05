//
//  CaptureDiagnostics.swift
//  GhostMeet
//

@preconcurrency import AVFoundation
import Foundation
import os

/// Temporary instrumentation for the "the app hears nothing" investigation.
///
/// The overlay cannot be screenshotted and shows no log of its own, so the only
/// way to see what the pipeline is doing on a real machine is the unified log:
///
///     log stream --predicate 'subsystem == "Mixxy.GhostMeet"' --info
///
/// Delete this file once the cause is found — it is a probe, not a feature.
@MainActor
final class CaptureDiagnostics {

    private let log = Logger(subsystem: "Mixxy.GhostMeet", category: "capture")

    private var frameCount: [Channel: Int] = [:]
    private var loudFrameCount: [Channel: Int] = [:]
    private var peakRMS: [Channel: Float] = [:]

    /// Frames arrive dozens of times a second, so the summary is periodic;
    /// what matters is whether they arrive at all and whether any of them clear
    /// the silence gate.
    func sawFrame(_ frame: AudioFrame, gate: Float) {
        let channel = frame.channel
        let count = (frameCount[channel] ?? 0) + 1
        frameCount[channel] = count

        let rms = frame.rms
        peakRMS[channel] = max(peakRMS[channel] ?? 0, rms)
        if rms >= gate { loudFrameCount[channel] = (loudFrameCount[channel] ?? 0) + 1 }

        guard count % 50 == 0 else { return }
        log.info("""
            канал=\(String(describing: channel), privacy: .public) \
            кадров=\(count, privacy: .public) \
            громких=\(self.loudFrameCount[channel] ?? 0, privacy: .public) \
            пик_rms=\(self.peakRMS[channel] ?? 0, privacy: .public) \
            порог=\(gate, privacy: .public)
            """)
    }

    func closedTurn(_ turn: CapturedTurn) {
        log.info("""
            РЕПЛИКА ЗАКРЫЛАСЬ канал=\(String(describing: turn.channel), privacy: .public) \
            длительность=\(turn.duration, privacy: .public)
            """)
    }

    func recognised(channel: Channel, text: String) {
        log.info("""
            РАСПОЗНАНО канал=\(String(describing: channel), privacy: .public) \
            символов=\(text.count, privacy: .public)
            """)
    }

    func recognitionFailed(channel: Channel, error: Error) {
        log.error("""
            РАСПОЗНАВАНИЕ НЕ УДАЛОСЬ канал=\(String(describing: channel), privacy: .public) \
            причина=\(error.localizedDescription, privacy: .public)
            """)
    }

    func captureStarted(_ names: [String]) {
        log.info("ЗАХВАТ СТАРТОВАЛ источники=\(names.joined(separator: ", "), privacy: .public)")
    }

    func captureFailed(_ error: Error) {
        log.error("ЗАХВАТ НЕ СТАРТОВАЛ причина=\(error.localizedDescription, privacy: .public)")
    }
}

/// Temporary probe for the `Them` side: the IOProc can run happily while every
/// buffer it hands over is dropped before it becomes a frame. From outside that
/// is indistinguishable from an IOProc that never fires.
///
/// Delete with `CaptureDiagnostics`.
final class TapProbe: @unchecked Sendable {

    private let log = Logger(subsystem: "Mixxy.GhostMeet", category: "capture")
    private let lock = NSLock()
    private var callbacks = 0
    private var madeCount = 0
    private var emptyCount = 0

    func sawCallback(
        buffers: UInt32,
        bytes: UInt32,
        madeBuffer: Bool,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) {
        lock.lock()
        callbacks += 1
        if madeBuffer { madeCount += 1 }
        if frames == 0 { emptyCount += 1 }
        let shouldLog = callbacks % 50 == 0 || callbacks == 1
        let snapshot = (callbacks, madeCount, emptyCount)
        lock.unlock()

        guard shouldLog else { return }
        log.info("""
            ТАП вызовов=\(snapshot.0, privacy: .public) \
            буфер_создан=\(snapshot.1, privacy: .public) \
            пустых=\(snapshot.2, privacy: .public) \
            списков=\(buffers, privacy: .public) байт=\(bytes, privacy: .public) \
            кадров=\(frames, privacy: .public) \
            формат=\(format.sampleRate, privacy: .public)Гц/\(format.channelCount, privacy: .public)кан/\
            \(format.isInterleaved ? "interleaved" : "planar", privacy: .public)
            """)
    }
}
