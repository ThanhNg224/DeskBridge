import AppKit
import CoreGraphics
import os

/// Everything about the Mac cursor while Android has control: park it, stop the Mac from seeing input,
/// hide it, and give it back. Used from the session queue only (except `swallowingProbe`).
///
/// The call order is the result of many rounds of real-world testing, see the cursor notes in CLAUDE.md:
/// move the cursor off whatever it hovers while events still pass (so the Dock clears its icon label),
/// cover the display with our own foreground window, warp again under it, then freeze and hide.
final class RemoteCursor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.deskbridge.app", category: "cursor")
    private static let beginSwallowingDelay = 0.05

    private let queue: DispatchQueue
    private let shield = CursorShield()
    private let swallowing = OSAllocatedUnfairLock(initialState: false)
    private var warpFilter = WarpFilter()
    private var engaged = false
    private var hidden = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// One-time setup when a session starts.
    func prepare() {
        CursorVisibility.allowHidingInBackground()
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0 // no freeze after warps
    }

    /// For the event tap thread: true while the Mac must not see mouse and keyboard events.
    func swallowingProbe() -> @Sendable () -> Bool {
        let swallowing = swallowing
        return { swallowing.withLock { $0 } }
    }

    /// True for the synthetic big move our own warp causes (see `WarpFilter`).
    func shouldIgnoreMove(dx: Double, dy: Double) -> Bool {
        warpFilter.shouldIgnore(dx: dx, dy: dy)
    }

    func engage(from location: CGPoint, on display: CGRect, edge: ScreenEdge) {
        engaged = true
        let parkDisplay = Displays.bounds(containing: location) ?? display
        let target = ParkingPoint.find(
            from: location, edge: edge, display: parkDisplay, isOccupied: Displays.isOccupiedByAnotherApp
        )
        CGWarpMouseCursorPosition(target)
        warpFilter.noteWarp()
        queue.asyncAfter(deadline: .now() + Self.beginSwallowingDelay) { [weak self] in
            guard let self, engaged else { return }
            swallowing.withLock { $0 = true }
            shield.show(covering: display) { [weak self] in
                self?.queue.async { self?.freeze(at: target) }
            }
        }
    }

    /// Gives the cursor back; `point` is where it reappears (nil: where it is).
    func release(returnTo point: CGPoint?) {
        engaged = false
        swallowing.withLock { $0 = false }
        CGAssociateMouseAndMouseCursorPosition(1)
        if hidden {
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
        shield.hide()
        if let point {
            CGWarpMouseCursorPosition(point)
        }
    }

    private func freeze(at target: CGPoint) {
        guard engaged, !hidden else { return }
        CGWarpMouseCursorPosition(target)
        warpFilter.noteWarp()
        CGAssociateMouseAndMouseCursorPosition(0) // freeze the Mac cursor; deltas keep flowing
        let hide = CGDisplayHideCursor(CGMainDisplayID())
        hidden = hide == .success
        Self.log.info("cursor frozen at (\(Int(target.x)),\(Int(target.y))) hide=\(hide.rawValue)")
    }
}
