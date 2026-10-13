import Foundation

/// Growing wait between attempts to start a session that keeps failing (2, 4, 8 ... capped at 30 s),
/// so a broken device or missing permission does not relaunch the server in a tight loop.
public struct Backoff: Equatable, Sendable {
    public static let base: TimeInterval = 2
    public static let maximum: TimeInterval = 30

    public private(set) var failures = 0

    public init() {}

    public var delay: TimeInterval {
        failures == 0 ? 0 : min(Self.base * pow(2, Double(failures - 1)), Self.maximum)
    }

    public mutating func recordFailure() {
        failures += 1
    }

    public mutating func reset() {
        failures = 0
    }
}
