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
        lock = OSAllocatedUnfairLock(initialState: values)
    }

    public var values: Values {
        get { lock.withLock { $0 } }
        set {
            lock.withLock { $0 = newValue }
            defaults.set(newValue.edge.rawValue, forKey: "edge")
            defaults.set(newValue.rightClickIsBack, forKey: "rightClickIsBack")
            defaults.set(newValue.pointerSpeed, forKey: "pointerSpeed")
        }
    }
}
