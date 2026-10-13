@testable import DeskBridgeCore
import Testing

struct BackoffTests {
    @Test func noWaitBeforeAnyFailure() {
        #expect(Backoff().delay == 0)
    }

    @Test func doublesFromTwoSecondsAndCapsAtThirty() {
        var backoff = Backoff()
        var delays: [Double] = []
        for _ in 0 ..< 7 {
            backoff.recordFailure()
            delays.append(backoff.delay)
        }
        #expect(delays == [2, 4, 8, 16, 30, 30, 30])
    }

    @Test func resetStartsOver() {
        var backoff = Backoff()
        backoff.recordFailure()
        backoff.recordFailure()
        backoff.reset()
        #expect(backoff.delay == 0)
        backoff.recordFailure()
        #expect(backoff.delay == 2)
    }
}
