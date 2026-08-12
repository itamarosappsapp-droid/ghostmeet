//
//  RecognizerSpy.swift
//  GhostMeetTests
//

import Foundation
@testable import GhostMeet

/// Recognition that remembers what it was asked to transcribe, so a test can
/// tell whether silence ever reached it.
///
/// **The conformance is declared in the extension below, and moving it there was
/// a fix, not a tidy-up.** `SpeechRecognizer` is a `nonisolated protocol`, and a
/// conformance written on the type declaration itself lets the type *infer* the
/// protocol's isolation — which for an `actor` is the one thing that cannot be
/// applied, so the compiler rejects the declaration with `'nonisolated' modifier
/// cannot be applied to this declaration`, pointing at a file that contains no
/// `nonisolated` at all. A conformance in an extension does not infer anything
/// onto the type.
///
/// It went unnoticed because the app target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, where the inference does not
/// happen, and `WhisperSpeechRecognizer` is an actor conforming to the very same
/// protocol. The test target has no such setting, so only the spies were exposed
/// — and only on some toolchains: Xcode 26.4 (Swift 6.3.0) compiled this, while
/// 16.4 (6.1) and 26.6 (6.3.3) both refused it. Do not fold the conformance back
/// into the declaration to «make it look like the app's».
actor RecognizerSpy {
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

extension RecognizerSpy: SpeechRecognizer {}
