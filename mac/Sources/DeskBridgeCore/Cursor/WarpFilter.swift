import Foundation

/// A cursor warp comes back through the event tap as one big mouse move. Those must not reach Android,
/// while the small, real moves right after a warp (the user is still pushing) must.
struct WarpFilter {
    static let window: TimeInterval = 0.3
    static let minimumDistance = 60.0

    private var windowEnd = Date.distantPast

    mutating func noteWarp(at now: Date = Date()) {
        windowEnd = now.addingTimeInterval(Self.window)
    }

    func shouldIgnore(dx: Double, dy: Double, at now: Date = Date()) -> Bool {
        now < windowEnd && hypot(dx, dy) >= Self.minimumDistance
    }
}
