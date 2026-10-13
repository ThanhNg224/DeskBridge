@testable import DeskBridgeCore
import Foundation
import Testing

struct WarpFilterTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func nothingIsIgnoredBeforeAnyWarp() {
        #expect(!WarpFilter().shouldIgnore(dx: 500, dy: 0, at: t0))
    }

    @Test func bigMovesRightAfterAWarpAreIgnored() {
        var filter = WarpFilter()
        filter.noteWarp(at: t0)
        #expect(filter.shouldIgnore(dx: 0, dy: -112, at: t0.addingTimeInterval(0.01)))
        #expect(filter.shouldIgnore(dx: 50, dy: 40, at: t0.addingTimeInterval(0.2))) // hypot ~64
    }

    @Test func smallRealMovesStillPassDuringTheWindow() {
        var filter = WarpFilter()
        filter.noteWarp(at: t0)
        #expect(!filter.shouldIgnore(dx: 3, dy: 8, at: t0.addingTimeInterval(0.1)))
        #expect(!filter.shouldIgnore(dx: 0, dy: 59, at: t0.addingTimeInterval(0.1)))
    }

    @Test func bigMovesPassOnceTheWindowIsOver() {
        var filter = WarpFilter()
        filter.noteWarp(at: t0)
        #expect(!filter.shouldIgnore(dx: 0, dy: -112, at: t0.addingTimeInterval(WarpFilter.window + 0.01)))
    }
}
