//
//  AppVersion.swift
//  GhostMeet
//

import Foundation

/// A released version of GhostMeet: `MAJOR.MINOR.PATCH` and nothing else.
///
/// Deliberately stricter than SemVer at both ends. It parses **only** three
/// numeric components, optionally behind the `v` that git tags carry — the same
/// shape `scripts/release.sh` refuses to deviate from — and it says nothing about
/// pre-release suffixes because a build tagged `v0.3.0-beta1` must not be offered
/// to somebody about to walk into an interview. Anything else fails to parse, and
/// a version that fails to parse is simply not compared: the update notice stays
/// away rather than guessing.
struct AppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads `0.2.0`, `v0.2.0` or ` V0.2.0 `; returns nil for everything else.
    ///
    /// Nil rather than a lenient best guess. The only caller compares this with
    /// the running build to decide whether to tell the user they are out of
    /// date, and a wrong parse there is either a notice that never goes away or
    /// one that never appears — both worse than silence.
    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        // `Int(…)` parses the whole slice or nothing, so " 1" and "1-beta" are
        // refused here — that is the pre-release filter as well as the garbage
        // filter. Leading zeros it does accept, and `01.2.3` is read as 1.2.3:
        // a tag nobody in this project writes, and reading it generously is a
        // smaller wrong than refusing a release that exists.
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }

        self.init(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

extension AppVersion {

    /// The version of the running bundle, read from `CFBundleShortVersionString`
    /// — which is `MARKETING_VERSION` after Xcode has substituted it.
    ///
    /// Optional because it genuinely can be absent: the tests host themselves
    /// inside the app, previews build their own bundles, and a build with no
    /// version is a build that must not claim to be out of date.
    static func running(in bundle: Bundle = .main) -> AppVersion? {
        guard let string = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(string)
    }
}
