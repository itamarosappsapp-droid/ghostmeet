//
//  UpdateCheck.swift
//  GhostMeet
//

import Foundation
import Observation

/// A release that has been published, as far as the app needs to know it.
struct PublishedRelease: Equatable, Sendable {
    let version: AppVersion
    /// The release page — where the notice sends the user. The page and not the
    /// image: what changed is read before a 4-megabyte download is started, and
    /// during a call the answer to «стоит ли обновляться прямо сейчас» is
    /// usually no.
    let page: URL
}

/// Where the newest published release is looked up.
///
/// A protocol because the only real implementation talks to the network, and
/// every rule worth testing here — newer wins, equal is silence, a failure is
/// silence — is about what the app does with the answer, not about how it was
/// fetched.
protocol ReleaseCatalog: Sendable {
    func latestRelease() async throws -> PublishedRelease?
}

// MARK: - GitHub

/// Reads the latest release from the GitHub API.
///
/// `/releases/latest` is used rather than the tag list on purpose: GitHub
/// excludes drafts and pre-releases from it, so a tag pushed for a colleague to
/// try never turns into a notice on somebody else's machine.
struct GitHubReleaseCatalog: ReleaseCatalog {

    /// The repository releases are published to. One place, so that a fork does
    /// not silently keep pointing at this one.
    static let ghostMeet = GitHubReleaseCatalog(owner: "slimgo", repository: "ghostmeet")

    let owner: String
    let repository: String

    /// Ten seconds and no retry. This is the least important request the app
    /// ever makes; the user is opening the window to go into a call.
    var timeout: TimeInterval = 10

    private var endpoint: URL? {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
    }

    func latestRelease() async throws -> PublishedRelease? {
        guard let endpoint else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub answers 403 to a request without a User-Agent. Nothing
        // identifying goes in it beyond the app and its version — the same two
        // facts the answer is about.
        let version = AppVersion.running().map(String.init(describing:)) ?? "unknown"
        request.setValue("GhostMeet/\(version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        return Self.release(from: data)
    }

    /// Turns the API's answer into a release, or into nothing.
    ///
    /// Separate from the request so the wire format can be exercised without a
    /// network, the way every other wire format in this project is.
    static func release(from data: Data) -> PublishedRelease? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = AppVersion(payload.tagName),
              let page = URL(string: payload.htmlURL) else { return nil }
        return PublishedRelease(version: version, page: page)
    }

    private struct Payload: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

// MARK: - The check itself

/// Whether a newer GhostMeet exists, and the one line of the window that says so.
///
/// The app is handed to colleagues as a disk image, so nothing else ever tells
/// them a new build exists: without this, a machine stays on the version it was
/// given until somebody remembers to ask.
///
/// **Every failure is silence.** No network, an offline coffee shop, a rate limit,
/// a repository that has no releases yet, a hand-edited tag that does not parse —
/// all of it ends the same way, with no notice and no error anywhere. This is the
/// least important thing the app does; it has no licence to take a line of the
/// window to complain about itself, and it posts no system notification for the
/// same reason nothing else here does (ADR-0004).
@MainActor
@Observable
final class UpdateCheck {

    /// The newer release, once one is known. Nil means "nothing to say" — which
    /// covers up to date, not checked, checked and failed, and dismissed.
    private(set) var available: PublishedRelease?

    private let catalog: any ReleaseCatalog
    private let runningVersion: AppVersion?
    private let isEnabled: @MainActor () -> Bool

    init(
        catalog: any ReleaseCatalog = GitHubReleaseCatalog.ghostMeet,
        runningVersion: AppVersion? = AppVersion.running(),
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.catalog = catalog
        self.runningVersion = runningVersion
        self.isEnabled = isEnabled
    }

    /// Asks once. Called at launch and nowhere else — the app is started for a
    /// call and closed after it, so a timer would only spend somebody's network
    /// on an answer that cannot have changed.
    func run() async {
        // Read at call time rather than at construction: the user may have
        // turned the check off in a previous session, and the setting is the
        // whole of their consent to this request.
        guard isEnabled() else { return }

        // Without a version of our own there is nothing to compare against, and
        // "newer than nothing" is not a claim worth making.
        guard let runningVersion else { return }

        guard let latest = try? await catalog.latestRelease() else { return }
        guard latest.version > runningVersion else { return }

        available = latest
    }

    /// Puts the notice away for this launch.
    ///
    /// Not remembered on disk, and that is the cheap answer to the awkward
    /// question of what "dismissed" means: it lasts as long as the window does.
    /// A user who dismisses it is saying «не сейчас, я иду на звонок», not «не
    /// говори мне об этой версии больше никогда».
    func dismiss() {
        available = nil
    }
}
