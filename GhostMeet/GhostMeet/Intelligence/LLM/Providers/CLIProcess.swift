//
//  CLIProcess.swift
//  GhostMeet
//

import Darwin
import Foundation

/// One run of a command-line tool: the prompt goes in on stdin, the answer comes
/// back on stdout in whatever pieces the tool writes it, and it can be killed.
///
/// This is the CLI equivalent of `StreamingHTTPTransport` — the plumbing kept
/// apart from `CLIProvider` so the provider reads as logic rather than as
/// `Process` bookkeeping.
///
/// `@unchecked Sendable` is deliberate: `Process` and `Pipe` are not `Sendable`,
/// yet a run is inherently touched from three places at once — the reading
/// callbacks, the writing queue, and whichever task cancels it. The mutable
/// state is exactly one buffer, guarded by a lock; everything else is either
/// immutable after `start` or `Process`'s own thread-safe surface.
nonisolated final class CLIProcess: @unchecked Sendable {

    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let input = Pipe()

    private let lock = NSLock()
    private var reportedErrors = Data()

    init(executable: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        // Tools that inspect the working directory (codex looks for a repo)
        // should not be pointed at whatever directory the app was launched from
        // — for a bundled app that is `/`.
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Launches the tool, feeds it the prompt, and hands back its stdout as it is
    /// written — which is what streaming means here: read the output as it
    /// appears instead of waiting for the process to exit.
    ///
    /// Throws when the tool cannot be launched at all.
    func start(prompt: String) throws -> AsyncStream<Data> {
        try process.run()
        collectStandardError()
        let stdout = readStandardOutput()
        write(prompt)
        return stdout
    }

    /// Kills the tool. Idempotent, and safe once it has already exited.
    ///
    /// `SIGTERM` first so the tool can close its own session cleanly, then
    /// `SIGKILL` if it ignores that. This is the point of the whole class: an
    /// abandoned run keeps writing an answer nobody will read and keeps spending
    /// the subscription that makes CLI providers worth having.
    ///
    /// Only the tool itself is signalled — it stays in our process group, so a
    /// grandchild it spawned and orphaned is beyond reach here.
    func terminate(killAfter grace: DispatchTimeInterval = .milliseconds(300)) {
        guard process.isRunning else { return }
        let running = process
        let identifier = process.processIdentifier

        running.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            if running.isRunning { kill(identifier, SIGKILL) }
        }
    }

    /// Waits for the tool to exit and reports its status. Only valid after a
    /// successful `start`.
    func waitForExit() async -> Int32 {
        let running = process
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                running.waitUntilExit()
                continuation.resume(returning: running.terminationStatus)
            }
        }
    }

    /// Whatever the tool wrote to stderr, which is where CLI tools explain
    /// themselves — "not logged in", "quota exceeded" — and the only wording
    /// worth showing the user when the run fails.
    var standardErrorText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: reportedErrors, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plumbing

    private func readStandardOutput() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let handle = output.fileHandleForReading
            handle.readabilityHandler = { source in
                let chunk = source.availableData
                // An empty read is EOF: the tool closed stdout or exited.
                guard !chunk.isEmpty else {
                    source.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(chunk)
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    private func collectStandardError() {
        let handle = errors.fileHandleForReading
        handle.readabilityHandler = { [weak self] source in
            let chunk = source.availableData
            guard !chunk.isEmpty else {
                source.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        reportedErrors.append(chunk)
        lock.unlock()
    }

    private func write(_ prompt: String) {
        let handle = input.fileHandleForWriting
        // A prompt bigger than the pipe buffer blocks until the tool reads it,
        // and blocking here would stall the very loop meant to be reading the
        // answer — so the write happens off to the side.
        let data = Data(prompt.utf8)

        // Writing to a pipe whose reader is gone — which is exactly what
        // cancellation creates — raises SIGPIPE and would take the whole app
        // down. Per-descriptor, so no global signal handler is touched.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, Int32(1))

        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

/// Turns pipe chunks into text without mangling a character that straddles two
/// reads.
///
/// Not a theoretical concern: a pipe hands over arbitrary byte counts, the
/// answers here are in Russian, and every Cyrillic letter is two bytes — so a
/// naive per-chunk decode drops a letter roughly whenever the tool flushes.
nonisolated struct IncrementalUTF8Text {

    private var pending = Data()

    /// Everything that can be decoded so far; a partial character at the end is
    /// held back for the next chunk.
    mutating func append(_ chunk: Data) -> String {
        pending.append(chunk)
        return take(expectingMore: true)
    }

    /// Whatever is left once the tool has closed its output.
    mutating func flush() -> String {
        take(expectingMore: false)
    }

    private mutating func take(expectingMore: Bool) -> String {
        guard !pending.isEmpty else { return "" }

        if let text = String(data: pending, encoding: .utf8) {
            pending.removeAll()
            return text
        }

        // A UTF-8 character is at most four bytes, so a split one leaves at most
        // three unusable bytes at the end.
        if expectingMore {
            for trimmed in 1...3 where pending.count >= trimmed {
                let head = pending.prefix(pending.count - trimmed)
                guard let text = String(data: head, encoding: .utf8) else { continue }
                pending.removeFirst(head.count)
                return text
            }
        }

        // Genuinely broken bytes rather than a split character: show the answer
        // with replacement characters rather than swallow it.
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }
}
