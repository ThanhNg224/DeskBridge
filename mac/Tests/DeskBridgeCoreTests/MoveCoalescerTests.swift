@testable import DeskBridgeCore
import Testing

struct MoveCoalescerTests {
    @Test func sendsImmediatelyWhenIdle() {
        var c = MoveCoalescer()
        let first = c.add(dx: 3, dy: -1)
        #expect(first?.dx == 3 && first?.dy == -1)
    }

    @Test func accumulatesWhileInFlightThenFlushesOnCompletion() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 1)
        #expect(c.add(dx: 2, dy: 0) == nil)
        #expect(c.add(dx: 3, dy: 5) == nil)
        let next = c.sendCompleted()
        #expect(next?.dx == 5 && next?.dy == 5)
        #expect(c.sendCompleted() == nil)
    }

    @Test func idleAgainAfterCompletionWithNothingPending() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 0)
        #expect(c.sendCompleted() == nil)
        #expect(c.add(dx: 4, dy: 4) != nil)
    }

    @Test func flushForcesPendingDeltaOut() {
        var c = MoveCoalescer()
        _ = c.add(dx: 1, dy: 0)
        _ = c.add(dx: 7, dy: 2)
        let flushed = c.flush()
        #expect(flushed?.dx == 7 && flushed?.dy == 2)
        #expect(c.flush() == nil)
    }
}
