import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct EdgeDetectorTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func rightEdgeCrossingReportsAlong() throws {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        let along = d.crossing(at: CGPoint(x: 1511, y: 491), deltaX: 4)
        #expect(try along != nil && abs(#require(along) - 0.5) < 0.001)
    }

    @Test func noCrossingWhenMovingInwardOrAwayFromEdge() {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 1511, y: 100), deltaX: -4) == nil)
        #expect(d.crossing(at: CGPoint(x: 700, y: 100), deltaX: 4) == nil)
    }

    @Test func leftEdgeCrossing() {
        let d = EdgeDetector(edge: .left, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: -1) == 0)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: 1) == nil)
    }

    @Test func returnPointIsInsetFromTheEdge() {
        let right = EdgeDetector(edge: .right, bounds: bounds).returnPoint(along: 0.5)
        #expect(right.x == bounds.maxX - 12)
        let left = EdgeDetector(edge: .left, bounds: bounds).returnPoint(along: 0)
        #expect(left == CGPoint(x: 12, y: 0))
    }

    @Test func androidEntryEdgeIsOpposite() {
        #expect(ScreenEdge.right.androidEntryEdge == .left)
        #expect(ScreenEdge.left.androidEntryEdge == .right)
    }
}
