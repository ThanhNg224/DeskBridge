import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct EdgeDetectorTests {
    let single = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// A 1920x1080 main display with a tall 1080x1920 portrait display on its left (taller on both ends).
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let portrait = CGRect(x: -1080, y: -325, width: 1080, height: 1920)

    private func detector(_ edge: ScreenEdge, _ displays: [CGRect]) -> EdgeDetector {
        EdgeDetector(edge: edge, displays: displays)
    }

    @Test func rightEdgeCrossingReportsAlong() throws {
        let crossing = detector(.right, [single]).crossing(at: CGPoint(x: 1511, y: 491), deltaX: 4, deltaY: 0)
        let along = try #require(crossing).along
        #expect(abs(along - 0.5) < 0.001)
    }

    @Test func noCrossingWhenMovingInwardOrAwayFromEdge() {
        let d = detector(.right, [single])
        #expect(d.crossing(at: CGPoint(x: 1511, y: 100), deltaX: -4, deltaY: 0) == nil)
        #expect(d.crossing(at: CGPoint(x: 700, y: 100), deltaX: 4, deltaY: 0) == nil)
    }

    @Test func leftEdgeCrossing() {
        let d = detector(.left, [single])
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: -1, deltaY: 0)?.along == 0)
        #expect(d.crossing(at: CGPoint(x: 0, y: 0), deltaX: 1, deltaY: 0) == nil)
    }

    @Test func bottomAndTopUseHorizontalPosition() throws {
        let bottom = detector(.bottom, [single]).crossing(at: CGPoint(x: 756, y: 981), deltaX: 0, deltaY: 3)
        #expect(try abs(#require(bottom).along - 0.5) < 0.001)
        #expect(detector(.bottom, [single]).crossing(at: CGPoint(x: 756, y: 981), deltaX: 0, deltaY: -3) == nil)
        #expect(detector(.bottom, [single]).crossing(at: CGPoint(x: 756, y: 500), deltaX: 0, deltaY: 3) == nil)
        #expect(detector(.top, [single]).crossing(at: CGPoint(x: 0, y: 0), deltaX: 0, deltaY: -1)?.along == 0)
    }

    // MARK: - several displays

    @Test func bottomEdgeOfTheShorterMainDisplayCountsEvenThoughTheUnionIsTaller() throws {
        // Regression: the union's bottom (y = 1595) is the portrait display's; the main display's own bottom
        // (y = 1079) has nothing below it and must still be an edge.
        let d = detector(.bottom, [main, portrait])
        let onMain = try #require(d.crossing(at: CGPoint(x: 960, y: 1079), deltaX: 0, deltaY: 2))
        #expect(onMain.display == main)
        #expect(abs(onMain.along - 0.5) < 0.001)
        #expect(d.crossing(at: CGPoint(x: -540, y: 1594), deltaX: 0, deltaY: 2)?.display == portrait)
    }

    @Test func topEdgeOfTheMainDisplayCounts() {
        let d = detector(.top, [main, portrait])
        #expect(d.crossing(at: CGPoint(x: 960, y: 0), deltaX: 0, deltaY: -2)?.display == main)
    }

    @Test func edgeBetweenTwoDisplaysIsNotAnEdge() {
        // Main's left edge touches the portrait display (y 0...1079 is inside its range).
        #expect(detector(.left, [main, portrait]).crossing(at: CGPoint(x: 0, y: 500), deltaX: -3, deltaY: 0) == nil)
        // The portrait display's own left edge is exposed.
        #expect(detector(.left, [main, portrait]).crossing(at: CGPoint(x: -1080, y: 500), deltaX: -3, deltaY: 0)?
            .display == portrait)
        // Right edge of the portrait display faces the main display for y in 0...1079 only.
        #expect(detector(.right, [main, portrait]).crossing(at: CGPoint(x: -1, y: 500), deltaX: 3, deltaY: 0) == nil)
        #expect(detector(.right, [main, portrait]).crossing(at: CGPoint(x: -1, y: 1400), deltaX: 3, deltaY: 0) != nil)
    }

    // MARK: - return point

    @Test func returnPointIsInsetOnTheDisplayItLeftFrom() {
        let right = detector(.right, [main, portrait]).returnPoint(along: 0.5, in: main)
        #expect(right.x == main.maxX - 12)
        #expect(detector(.left, [single]).returnPoint(along: 0, in: single) == CGPoint(x: 12, y: 0))
        #expect(detector(.top, [single]).returnPoint(along: 0, in: single) == CGPoint(x: 0, y: 12))
        let bottom = detector(.bottom, [single]).returnPoint(along: 1, in: single)
        #expect(bottom == CGPoint(x: single.maxX - 1, y: single.maxY - 12))
        // Bottom return on the main display lands on that display, not on the union's bottom.
        #expect(detector(.bottom, [main, portrait]).returnPoint(along: 0.5, in: main).y == main.maxY - 12)
    }

    @Test func androidEntryEdgeIsOpposite() {
        #expect(ScreenEdge.right.androidEntryEdge == .left)
        #expect(ScreenEdge.left.androidEntryEdge == .right)
        #expect(ScreenEdge.bottom.androidEntryEdge == .top)
        #expect(ScreenEdge.top.androidEntryEdge == .bottom)
    }
}
