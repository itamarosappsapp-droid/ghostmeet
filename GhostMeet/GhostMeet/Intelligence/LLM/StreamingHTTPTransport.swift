//
//  StreamingHTTPTransport.swift
//  GhostMeet
//

import Foundation

/// One streaming HTTP exchange: the status code, plus the body delivered line by
/// line while it is still arriving.
nonisolated struct HTTPLineStream: Sendable {

    let statusCode: Int

    /// Body lines in order, newlines already stripped.
    ///
    /// Terminating this stream must abandon the connection rather than let it
    /// drain in the background — that is what makes the cancellation promised by
    /// `LLMProvider` real instead of cosmetic.
    let lines: AsyncThrowingStream<String, any Error>

    init(statusCode: Int, lines: AsyncThrowingStream<String, any Error>) {
        self.statusCode = statusCode
        self.lines = lines
    }
}

/// The seam between a provider and the network.
///
/// It exists so a provider can be driven from a test without a socket: the wire
/// format, the mapping of failures and the cancellation path are all exercised
/// against a transport that replays canned lines.
nonisolated protocol StreamingHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPLineStream
}

/// The real transport: `URLSession` with the body consumed as it arrives.
nonisolated struct URLSessionStreamingTransport: StreamingHTTPTransport {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> HTTPLineStream {
        let (bytes, response) = try await session.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let pump = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Whoever stops reading stops the download: cancelling the pump
            // cancels the iteration of `bytes`, which tears the connection down.
            continuation.onTermination = { _ in pump.cancel() }
        }
        return HTTPLineStream(statusCode: statusCode, lines: lines)
    }
}
