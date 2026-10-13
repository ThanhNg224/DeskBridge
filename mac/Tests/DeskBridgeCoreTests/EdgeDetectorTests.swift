import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct EdgeDetectorTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func rightEdgeCrossingReportsAlong() throws {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        let along = d.crossing(at: CGPoint(x: 1511, y: 491), deltaX: 4, deltaY: 0)
        #expect(try along != nil && abs(#require(along) - 0.5) < 0.001)
    }

    @Test func noCrossingWhenMovingInwardOrAwayFromEdge() {
        let d = EdgeDetector(edge: .right, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 1511, y: 100), deltaX: -4, deltaY: 0) == nil)
        #expect(d.crossing(at: CGPoint(x: 700, y: 100), deltaX: 4, deltaY: 0) == nil)
    }

    @Test func leftEdgeCrossing() {
        let d = EdgeDetector(edge: .left, bounds: bounds)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: -1, deltaY: 0) == 0)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: 1, deltaY: 0) == nil)
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

    @Test func bottomEdgeReportsHorizontalPosition() throws {
        let d = EdgeDetector(edge: .bottom, bounds: bounds)
        let along = d.crossing(at: CGPoint(x: 756, y: 981), deltaX: 0, deltaY: 3)
        #expect(try along != nil && abs(#require(along) - 0.5) < 0.001)
        #expect(d.crossing(at: CGPoint(x: 756, y: 981), deltaX: 0, deltaY: -3) == nil)
        #expect(d.crossing(at: CGPoint(x: 756, y: 500), deltaX: 0, deltaY: 3) == nil)
    }

    @Test func topEdgeAndReturnPoints() {
        let top = EdgeDetector(edge: .top, bounds: bounds)
        #expect(top.crossing(at: CGPoint(x: 0, y: 0), deltaX: 0, deltaY: -1) == 0)
        #expect(top.returnPoint(along: 0) == CGPoint(x: 0, y: 12))
        let bottom = EdgeDetector(edge: .bottom, bounds: bounds).returnPoint(along: 1)
        #expect(bottom == CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 12))
    }

    @Test func androidEntryEdgeForVerticalLayouts() {
        #expect(ScreenEdge.bottom.androidEntryEdge == .top)
        #expect(ScreenEdge.top.androidEntryEdge == .bottom)
    }
}
