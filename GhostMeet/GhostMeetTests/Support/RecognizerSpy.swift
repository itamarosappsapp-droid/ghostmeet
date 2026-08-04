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

    init(reply: String = "") {
        self.reply = reply
    }

    func transcribe(_ audio: SpeechAudio) async throws -> String {
        requests.append(audio)
        return reply
    }
}
