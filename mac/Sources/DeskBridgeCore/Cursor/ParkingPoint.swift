import CoreGraphics

/// Where to leave the frozen Mac cursor while Android has control: inside the screen it left from and where
/// no other app's window sits (that app would own the cursor image, e.g. the Dock at the bottom edge).
enum ParkingPoint {
    static let distances: [CGFloat] = [120, 240, 400]
    static let offsets: [CGFloat] = [0, -250, 250, -500, 500]
    static let margin: CGFloat = 24
    static let fallbackDistance: CGFloat = 120

    /// Tries points further inside the screen first, then sideways along the edge; falls back to the first
    /// inward point when everything is occupied.
    static func find(
        from location: CGPoint, edge: ScreenEdge, display: CGRect, isOccupied: (CGPoint) -> Bool
    ) -> CGPoint {
        let usable = display.insetBy(dx: margin, dy: margin)
        let inward = inwardVector(for: edge)
        let along = CGVector(dx: abs(inward.dy), dy: abs(inward.dx))
        for distance in distances {
            for offset in offsets {
                let point = CGPoint(
                    x: location.x + inward.dx * distance + along.dx * offset,
                    y: location.y + inward.dy * distance + along.dy * offset
                )
                if usable.contains(point), !isOccupied(point) {
                    return point
                }
            }
        }
        return CGPoint(
            x: location.x + inward.dx * fallbackDistance, y: location.y + inward.dy * fallbackDistance
        )
    }

    static func inwardVector(for edge: ScreenEdge) -> CGVector {
        switch edge {
        case .bottom: CGVector(dx: 0, dy: -1)
        case .top: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
    }
}
