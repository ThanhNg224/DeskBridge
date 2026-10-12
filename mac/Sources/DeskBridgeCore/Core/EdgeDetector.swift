import CoreGraphics

/// Mac screen edge where the Android device "sits".
public enum ScreenEdge: Int, Sendable, CaseIterable {
    case left = 0
    case right = 1

    /// The Android edge the pointer appears on is the opposite one.
    public var androidEntryEdge: AndroidEdge {
        self == .right ? .left : .right
    }
}

public struct EdgeDetector: Sendable {
    public let edge: ScreenEdge
    /// Union of all displays in global coordinates, so moving between Mac displays never counts as an edge.
    public let bounds: CGRect

    private static let tolerance: CGFloat = 1.5

    public init(edge: ScreenEdge, bounds: CGRect) {
        self.edge = edge
        self.bounds = bounds
    }

    /// If the cursor sits on the configured edge and pushes outward, returns the normalized
    /// position (0...1) along that edge; otherwise nil.
    public func crossing(at point: CGPoint, deltaX: Double) -> Float? {
        switch edge {
        case .right: guard point.x >= bounds.maxX - Self.tolerance, deltaX > 0 else { return nil }
        case .left: guard point.x <= bounds.minX + Self.tolerance, deltaX < 0 else { return nil }
        }
        guard bounds.height > 0 else { return 0.5 }
        return Float(min(max((point.y - bounds.minY) / bounds.height, 0), 1))
    }

    /// Where to put the Mac cursor when control returns (slightly inside, so it does not re-trigger).
    public func returnPoint(along: Float, inset: CGFloat = 12) -> CGPoint {
        CGPoint(
            x: edge == .right ? bounds.maxX - inset : bounds.minX + inset,
            y: bounds.minY + CGFloat(along) * (bounds.height - 1)
        )
    }

    public static func currentBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }
}
