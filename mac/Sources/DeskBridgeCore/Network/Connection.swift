import Foundation
import Network

/// TCP connection to the forwarded server port. All callbacks run on `queue`.
public final class Connection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    /// Set before `start()`.
    public var onReady: (@Sendable () -> Void)?
    public var onData: (@Sendable (Data) -> Void)?
    /// Fires once: failure, refusal, EOF or `cancel()`.
    public var onClosed: (@Sendable () -> Void)?

    public init(port: UInt16, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // mouse deltas are tiny; Nagle would batch them
        connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? 1,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady?()
                receiveLoop()
            case .failed, .cancelled, .waiting: // .waiting == connection refused; the caller retries
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ data: Data, completion: (@Sendable () -> Void)? = nil) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.close()
            }
            completion?()
        })
    }

    public func cancel() {
        queue.async { self.close() }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                onData?(data)
            }
            if isComplete || error != nil {
                close()
            } else {
                receiveLoop()
            }
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed?()
    }
}
