import Foundation
import os

/// User settings, readable from any thread and persisted to UserDefaults.
public final class Settings: @unchecked Sendable {
    public struct Values: Equatable, Sendable {
        public var edge: ScreenEdge = .right
        /// true: right click sends Android Back; false: a real secondary button press.
        public var rightClickIsBack = true
        /// Mac points -> Android pixels multiplier for pointer deltas.
        public var pointerSpeed: Double = 2.0
        /// Flip scroll direction (Android axis sign).
        public var invertScroll = false
        /// Multiplier for wheel/trackpad scrolling.
        public var scrollSpeed: Double = 1.0
        /// true: Cmd acts as Ctrl (Cmd+C/V/A work). false: Cmd becomes the Android Meta key.
        public var commandIsControl = true
        /// Master switch of the app: off keeps it idle.
        public var enabled = true
        /// Show the app in the Dock (otherwise it only lives in the menu bar).
        public var showDockIcon = true
        /// Share the clipboard (text) when the pointer crosses between Mac and phone.
        public var shareClipboard = true
        /// Serial of the phone to use when several are attached.
        public var preferredSerial: String?
    }

    private let lock: OSAllocatedUnfairLock<Values>
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var values = Values()
        if let raw = defaults.object(forKey: "edge") as? Int, let edge = ScreenEdge(rawValue: raw) {
            values.edge = edge
        }
        if let back = defaults.object(forKey: "rightClickIsBack") as? Bool {
            values.rightClickIsBack = back
        }
        if let speed = defaults.object(forKey: "pointerSpeed") as? Double {
            values.pointerSpeed = speed
        }
        if let invert = defaults.object(forKey: "invertScroll") as? Bool {
            values.invertScroll = invert
        }
        if let speed = defaults.object(forKey: "scrollSpeed") as? Double {
            values.scrollSpeed = speed
        }
        if let cmd = defaults.object(forKey: "commandIsControl") as? Bool {
            values.commandIsControl = cmd
        }
        if let enabled = defaults.object(forKey: "enabled") as? Bool {
            values.enabled = enabled
        }
        if let dock = defaults.object(forKey: "showDockIcon") as? Bool {
            values.showDockIcon = dock
        }
        if let share = defaults.object(forKey: "shareClipboard") as? Bool {
            values.shareClipboard = share
        }
        values.preferredSerial = defaults.string(forKey: "preferredSerial")
        lock = OSAllocatedUnfairLock(initialState: values)
    }

    public var values: Values {
        get { lock.withLock { $0 } }
        set {
            lock.withLock { $0 = newValue }
            defaults.set(newValue.edge.rawValue, forKey: "edge")
            defaults.set(newValue.rightClickIsBack, forKey: "rightClickIsBack")
            defaults.set(newValue.pointerSpeed, forKey: "pointerSpeed")
            defaults.set(newValue.invertScroll, forKey: "invertScroll")
            defaults.set(newValue.scrollSpeed, forKey: "scrollSpeed")
            defaults.set(newValue.commandIsControl, forKey: "commandIsControl")
            defaults.set(newValue.enabled, forKey: "enabled")
            defaults.set(newValue.showDockIcon, forKey: "showDockIcon")
            defaults.set(newValue.shareClipboard, forKey: "shareClipboard")
            defaults.set(newValue.preferredSerial, forKey: "preferredSerial")
        }
    }
}
