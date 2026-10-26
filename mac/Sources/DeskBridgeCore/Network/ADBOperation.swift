import Foundation

/// Shared cancellation and monotonic deadline for a sequence of ADB commands.
public final class ADBOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: TimeInterval

    public init(timeout: TimeInterval = 30) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
    }

    public var remaining: TimeInterval {
        max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled {
            throw CancellationError()
        }
        if remaining <= 0 {
            throw ADBError.operationTimedOut
        }
    }
}
