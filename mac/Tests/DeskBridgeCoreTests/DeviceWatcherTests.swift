@testable import DeskBridgeCore
import Foundation
import Network
import os
import Testing

/// A stand-in for the adb server: answers `host:track-devices` with OKAY and one frame, and can drop the connection.
private final class FakeAdbServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-adb")
    private let state = OSAllocatedUnfairLock(initialState: (requests: [String](), connections: [NWConnection]()))

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    var requests: [String] {
        state.withLock { $0.requests }
    }

    func start() async -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            state.withLock { $0.connections.append(connection) }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [self] data, _, _, _ in
                state.withLock { $0.requests.append(String(decoding: data ?? Data(), as: UTF8.self)) }
                connection.send(content: Data("OKAY0013RF8NA2EZKZK\tdevice".utf8), completion: .idempotent)
            }
        }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state, !resumed.withLock({ let was = $0; $0 = true; return was }) {
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: queue)
        }
    }

    func dropConnections() {
        let connections = state.withLock { state -> [NWConnection] in
            defer { state.connections = [] }
            return state.connections
        }
        connections.forEach { $0.cancel() }
    }

    func stop() {
        listener.cancel()
    }
}

struct DeviceWatcherTests {
    private func wait(until condition: () -> Bool, seconds: Double = 5) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func requestIsLengthPrefixed() {
        #expect(String(decoding: DeviceWatcher.request("host:track-devices"), as: UTF8.self) ==
            "0012host:track-devices")
    }

    @Test func reportsChangesAndReconnectsWhenTheServerDrops() async throws {
        let server = try FakeAdbServer()
        let port = await server.start()
        defer { server.stop() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let watcher = DeviceWatcher(adbPath: "/usr/bin/true", port: port, restartDelay: 0.05)
        watcher.start { calls.withLock { $0 += 1 } }

        await wait { calls.withLock { $0 } >= 1 }
        #expect(watcher.isAlive)
        #expect(server.requests == ["0012host:track-devices"])

        let before = calls.withLock { $0 }
        server.dropConnections() // adb server restarted: reported once, then tracked again
        await wait { server.requests.count >= 2 && calls.withLock { $0 } > before }
        #expect(server.requests.count >= 2)
        #expect(calls.withLock { $0 } > before)

        watcher.stop()
        await wait { !watcher.isAlive }
        #expect(!watcher.isAlive)
    }
}
