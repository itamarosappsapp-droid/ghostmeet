//
//  AppDefaults.swift
//  GhostMeet
//

import Foundation

/// Which `UserDefaults` the app's stores are built on.
///
/// `xcodebuild test` hosts the test bundle inside `GhostMeet.app`, so a test run
/// launches the app for real: the delegate walks its whole launch path and the
/// overlay puts itself on screen. Everything that launch persists — the overlay
/// frame, its opacity, the profile, the thresholds — would land in the user's own
/// `Mixxy.GhostMeet` domain and still be there afterwards, with the window left
/// wherever the test host happened to place it (a frame with a negative X, in the
/// case that started this).
///
/// The choice of domain is therefore made once, here, where the app is composed.
/// Nothing below this type learns that tests exist: `SettingsStore` and
/// `WindowStateStore` simply persist into the defaults they are handed.
nonisolated enum AppDefaults {

    /// Domain the app writes into while it is being used as a test host.
    ///
    /// A fixed name rather than a fresh one per run: a run then leaves behind at
    /// most this one throwaway domain instead of a trail of them, and it is
    /// emptied as it is handed out, so no run ever reads what an earlier one
    /// wrote.
    static let testRunSuiteName = "Mixxy.GhostMeet.test-run"

    /// Defaults for this process: the user's own for an ordinary launch, a
    /// throwaway domain when the test runner started us.
    static func forCurrentProcess() -> UserDefaults {
        current(environment: ProcessInfo.processInfo.environment)
    }

    /// The same choice made against a given environment, so that both a test run
    /// and an ordinary launch can be exercised.
    static func current(environment: [String: String]) -> UserDefaults {
        isRunningTests(in: environment) ? throwawayDefaults() : .standard
    }

    /// Whether the test runner started this process.
    ///
    /// The evidence is in the environment: Xcode hands the test host its
    /// configuration through `XCTest…` variables (`XCTestConfigurationFilePath`,
    /// `XCTestBundlePath`, `XCTestSessionIdentifier`), and it does so for Swift
    /// Testing too, because the bundle is still loaded by the XCTest host.
    /// Matching the prefix rather than one exact name keeps this working when the
    /// set of variables shifts between Xcode versions.
    static func isRunningTests(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    /// A domain that belongs to nobody, emptied before it is used.
    private static func throwawayDefaults() -> UserDefaults {
        // `UserDefaults(suiteName:)` returns `nil` only for the app's own bundle
        // identifier and for the global domain; this constant is neither, so the
        // unwrap cannot fail. Falling back to `.standard` here would silently
        // reintroduce exactly the bug this type exists to prevent.
        let defaults = UserDefaults(suiteName: testRunSuiteName)!
        defaults.removePersistentDomain(forName: testRunSuiteName)
        return defaults
    }
}
