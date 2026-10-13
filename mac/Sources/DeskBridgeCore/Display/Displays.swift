import CoreGraphics
import Foundation

/// Reads of the current display and window layout (global CoreGraphics coordinates, origin top-left).
enum Displays {
    struct WindowInfo {
        let owner: String
        let layer: Int
    }

    static func current() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    static func primary() -> CGRect {
        CGDisplayBounds(CGMainDisplayID())
    }

    static func bounds(containing point: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return CGDisplayBounds(display)
    }

    /// Front-most on-screen window containing `point`, if any.
    static func frontWindow(at point: CGPoint) -> WindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  CGRect(x: x, y: y, width: w, height: h).contains(point)
            else { continue }
            return WindowInfo(
                owner: window[kCGWindowOwnerName as String] as? String ?? "?",
                layer: window[kCGWindowLayer as String] as? Int ?? 0
            )
        }
        return nil
    }

    /// A window of another app (above the desktop) sits at `point`.
    static func isOccupiedByAnotherApp(_ point: CGPoint) -> Bool {
        guard let window = frontWindow(at: point) else { return false }
        return window.layer >= 0 && window.owner != ProcessInfo.processInfo.processName
    }
}
