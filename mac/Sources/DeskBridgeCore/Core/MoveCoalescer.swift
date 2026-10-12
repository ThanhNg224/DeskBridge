/// Merges mouse deltas while a send is still in flight. Not thread-safe: use from one queue.
public struct MoveCoalescer: Sendable {
    public struct Delta: Equatable, Sendable {
        public let dx: Float
        public let dy: Float
    }

    private var pendingX: Float = 0
    private var pendingY: Float = 0
    private var inFlight = 0

    public init() {}

    /// Returns the delta to send now, or nil if a send is in flight (the delta is kept).
    public mutating func add(dx: Float, dy: Float) -> Delta? {
        pendingX += dx
        pendingY += dy
        return inFlight == 0 ? take() : nil
    }

    /// Call when a previously returned delta was handed to the network. Returns the next delta, if any.
    public mutating func sendCompleted() -> Delta? {
        inFlight = max(0, inFlight - 1)
        return inFlight == 0 ? take() : nil
    }

    /// Takes the pending delta even if a send is in flight (before a button/key, to keep ordering).
    public mutating func flush() -> Delta? {
        take()
    }

    private mutating func take() -> Delta? {
        guard pendingX != 0 || pendingY != 0 else { return nil }
        let delta = Delta(dx: pendingX, dy: pendingY)
        pendingX = 0
        pendingY = 0
        inFlight += 1
        return delta
    }
}
