import CoreGraphics

/// Mac screen edge where the Android device "sits".
public enum ScreenEdge: Int, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case bottom = 2
    case top = 3

    /// The Android edge the pointer appears on is the opposite one.
    public var androidEntryEdge: AndroidEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    var isHorizontal: Bool {
        self == .left || self == .right
    }
}

public struct EdgeDetector: Sendable {
    /// A crossing of an exposed screen edge: the display it happened on and where along that edge.
    public struct Crossing: Equatable, Sendable {
        /// Normalized position (0...1) along the edge (vertical for left/right, horizontal for top/bottom).
        public let along: Float
        /// The display whose edge was crossed (global CoreGraphics coordinates).
        public let display: CGRect
    }

    public let edge: ScreenEdge
    /// Every active display in global coordinates. An edge only counts where no other display sits right
    /// behind it, so moving between Mac displays never triggers and a short display next to a tall one
    /// still has its own exposed edges.
    public let displays: [CGRect]

    /// When set, top and bottom edges only count on this display (the main display), so a taller or
    /// rotated secondary display never gets in the way. Left and right use every exposed edge.
    public let primary: CGRect?

    private static let tolerance: CGFloat = 1.5

    public init(edge: ScreenEdge, displays: [CGRect], primary: CGRect? = nil) {
        self.edge = edge
        self.displays = displays
        self.primary = primary
    }

    /// Union of all displays.
    public var bounds: CGRect {
        displays.reduce(CGRect.null) { $0.union($1) }
    }

    /// If the cursor sits on an exposed edge of its display and pushes outward, returns where.
    public func crossing(at point: CGPoint, deltaX: Double, deltaY: Double) -> Crossing? {
        guard let display = displays.first(where: { $0.contains(point) }) else { return nil }
        if !edge.isHorizontal, let primary, display != primary {
            return nil
        }
        let outside: CGPoint
        switch edge {
        case .right:
            guard point.x >= display.maxX - Self.tolerance, deltaX > 0 else { return nil }
            outside = CGPoint(x: display.maxX + 1, y: point.y)
        case .left:
            guard point.x <= display.minX + Self.tolerance, deltaX < 0 else { return nil }
            outside = CGPoint(x: display.minX - 1, y: point.y)
        case .bottom:
            guard point.y >= display.maxY - Self.tolerance, deltaY > 0 else { return nil }
            outside = CGPoint(x: point.x, y: display.maxY + 1)
        case .top:
            guard point.y <= display.minY + Self.tolerance, deltaY < 0 else { return nil }
            outside = CGPoint(x: point.x, y: display.minY - 1)
        }
        guard !displays.contains(where: { $0.contains(outside) }) else { return nil }

        let (position, origin, length) = edge.isHorizontal
            ? (point.y, display.minY, display.height)
            : (point.x, display.minX, display.width)
        guard length > 0 else { return Crossing(along: 0.5, display: display) }
        return Crossing(along: Float(min(max((position - origin) / length, 0), 1)), display: display)
    }

    /// Where to put the Mac cursor when control returns: on the display it left from, slightly inside,
    /// so it does not re-trigger.
    public func returnPoint(along: Float, in display: CGRect, inset: CGFloat = 12) -> CGPoint {
        let t = CGFloat(along)
        switch edge {
        case .right: return CGPoint(x: display.maxX - inset, y: display.minY + t * (display.height - 1))
        case .left: return CGPoint(x: display.minX + inset, y: display.minY + t * (display.height - 1))
        case .bottom: return CGPoint(x: display.minX + t * (display.width - 1), y: display.maxY - inset)
        case .top: return CGPoint(x: display.minX + t * (display.width - 1), y: display.minY + inset)
        }
    }
}
