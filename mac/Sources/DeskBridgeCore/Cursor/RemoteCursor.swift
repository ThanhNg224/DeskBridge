import AppKit
import CoreGraphics
import os

/// Everything about the Mac cursor while Android has control: park it, stop the Mac from seeing input,
/// hide it, and give it back. Used from the session queue only (except `swallowingProbe`).
///
/// The call order is the result of many rounds of real-world testing, see the cursor notes in CLAUDE.md:
/// hide the cursor at once, cover the display with our own foreground window (it shows a transparent cursor,
/// which also works where the system ignores the hide, i.e. over the Dock), warp the cursor off whatever it
/// hovers (so the Dock clears its icon label; one marked synthetic move tells it), and freeze at once.
final class RemoteCursor: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.deskbridge.app", category: "cursor")
    private static let freezeDelay = 0.05
    private static let verifyDelay = 0.12
    private static let maxRetries = 4

    private let queue: DispatchQueue
    private let shield = CursorShield()
    private let swallowing = OSAllocatedUnfairLock(initialState: false)
    private var warpFilter = WarpFilter()
    private var engaged = false
    private var hidden = false
    private var frozen = false

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
        frozen = false
        Self.log.debug("engage at (\(Int(location.x)),\(Int(location.y))) edge=\(edge.rawValue)")
        hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success // before anything moves: nothing visible
        let parkDisplay = Displays.bounds(containing: location) ?? display
        let target = ParkingPoint.find(
            from: location, edge: edge, display: parkDisplay, isOccupied: Displays.isOccupiedByAnotherApp
        )
        // The shield goes up first so the cursor is already transparent when it is moved (over the Dock the
        // system ignores `hide`, so the move would otherwise be visible).
        let queue = queue
        shield.show(covering: display) { [weak self] in
            guard let cursor = self else { return }
            queue.async { cursor.park(at: target) }
        }
    }

    /// Gives the cursor back; `point` is where it reappears (nil: where it is).
    func release(returnTo point: CGPoint?) {
        engaged = false
        frozen = false
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

    /// Moves the cursor off whatever it hovers (so the Dock clears its icon label), then freezes it `freezeDelay`
    /// later.
    ///
    /// Both steps need a zero-delta move after the warp (`syntheticMarker`, let through by the event tap): a warp alone
    /// does not tell the Dock the pointer left, nor the window server to apply the shield's transparent cursor at the
    /// new spot. The freeze waits so that cursor update can happen (disassociating at once skipped it and the arrow
    /// stayed), and the user's real moves during that wait can drag the cursor back onto the Dock icon, so the freeze
    /// warps to the target once more.
    private func park(at target: CGPoint) {
        guard engaged else { return }
        warpAndNotify(to: target)
        queue.asyncAfter(deadline: .now() + Self.freezeDelay) { [weak self] in self?.freeze(at: target) }
    }

    private func warpAndNotify(to target: CGPoint) {
        CGWarpMouseCursorPosition(target)
        warpFilter.noteWarp()
        postSyntheticMove(at: target)
    }

    private func postSyntheticMove(at point: CGPoint) {
        let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        move?.setIntegerValueField(.eventSourceUserData, value: InputCapturer.syntheticMarker)
        move?.post(tap: .cghidEventTap)
    }

    private func freeze(at target: CGPoint) {
        guard engaged, !frozen else { return }
        frozen = true
        swallowing.withLock { $0 = true }
        warpAndNotify(to: target)
        CGAssociateMouseAndMouseCursorPosition(0) // freeze the Mac cursor; deltas keep flowing
        verifyBlankCursor(at: target, attempt: 0)
    }

    /// The shield's transparent cursor is sometimes not applied (seen after the Mac was idle for a while; the arrow
    /// then stays visible). `NSCursor.currentSystem` tells, so check and escalate: re-apply the cursor rects, take
    /// key/active status again, finally let the window server see a move with the cursor associated for a moment.
    private func verifyBlankCursor(at target: CGPoint, attempt: Int) {
        queue.asyncAfter(deadline: .now() + Self.verifyDelay) { [weak self] in
            guard let self, engaged else { return }
            shield.cursorIsBlank { [weak self] blank in
                guard let self else { return }
                queue.async { [self] in
                    guard engaged else { return }
                    if blank || attempt >= Self.maxRetries {
                        report(blank: blank, retries: attempt, at: target)
                        return
                    }
                    shield.refreshCursor(reactivate: attempt >= 1)
                    if attempt >= 2 {
                        nudge(at: target)
                    }
                    verifyBlankCursor(at: target, attempt: attempt + 1)
                }
            }
        }
    }

    /// Associates the cursor for a moment so the window server evaluates the cursor under it, then freezes it again.
    private func nudge(at target: CGPoint) {
        CGAssociateMouseAndMouseCursorPosition(1)
        warpAndNotify(to: target)
        queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, engaged else { return }
            warpAndNotify(to: target)
            CGAssociateMouseAndMouseCursorPosition(0)
        }
    }

    private func report(blank: Bool, retries: Int, at target: CGPoint) {
        let x = Int(target.x), y = Int(target.y)
        if blank, retries == 0 {
            Self.log.info("cursor frozen at (\(x),\(y))")
        } else if blank {
            Self.log.notice("cursor frozen at (\(x),\(y)) after \(retries) retries")
        } else {
            let top = Displays.frontWindow(at: target)
            let owner = top?.owner ?? "none"
            let layer = top?.layer ?? 0
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            Self.log.error("""
            cursor still visible after \(retries) retries at (\(x),\(y)): \
            top=\(owner, privacy: .public)/\(layer) front=\(front, privacy: .public)
            """)
        }
    }
}
