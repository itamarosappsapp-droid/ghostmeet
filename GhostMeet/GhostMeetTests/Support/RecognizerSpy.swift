//
//  RecognizerSpy.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// Recognition that remembers what it was asked to transcribe, so a test can
/// tell whether silence ever reached it.
actor RecognizerSpy: SpeechRecognizer {
    private(set) var requests: [SpeechAudio] = []
    private let reply: String
    /// Ответы по очереди, когда в сценарии несколько разных реплик: без этого
    /// две подряд заданные фразы неотличимы в транскрипте.
    private var queued: [String]

    init(reply: String = "") {
        self.reply = reply
        self.queued = []
    }

    init(replies: [String]) {
        self.reply = ""
        self.queued = replies
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        requests.append(audio)
        guard !queued.isEmpty else { return reply }
        return queued.removeFirst()
    }
}
