//
//  WindowStateStore.swift
//  GhostMeet
//

import CoreGraphics
import Foundation

/// Persists the overlay geometry and opacity between launches.
///
/// Deliberately free of AppKit: it stores four numbers and one fraction, so the
/// window layer can be exercised without putting a window on screen.
struct WindowStateStore {

    private enum Key {
        static let frame = "overlay.window.frame"
        static let opacity = "overlay.window.opacity"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Frame in screen coordinates. `nil` when nothing has been stored yet or the
    /// stored value is not a well-formed rectangle (a truncated or hand-edited
    /// preference must never produce a zero-sized window).
    var frame: CGRect? {
        get {
            guard let numbers = defaults.array(forKey: Key.frame) as? [Double],
                  numbers.count == 4,
                  numbers[2] > 0,
                  numbers[3] > 0
            else { return nil }
            return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.frame)
                return
            }
            defaults.set(
                [newValue.origin.x, newValue.origin.y, newValue.size.width, newValue.size.height],
                forKey: Key.frame
            )
        }
    }

    /// Window opacity, `nil` while the user has never touched the slider.
    var opacity: Double? {
        get {
            guard defaults.object(forKey: Key.opacity) != nil else { return nil }
            return defaults.double(forKey: Key.opacity)
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.opacity)
                return
            }
            defaults.set(newValue, forKey: Key.opacity)
        }
    }
}
