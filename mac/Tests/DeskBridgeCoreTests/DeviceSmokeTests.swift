@testable import DeskBridgeCore
import Foundation
import os
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_DEVICE"] != nil))
struct DeviceSmokeTests {
    @Test func handshakeSucceedsWithToken() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await handshake(port: server.port, token: server.token)
        guard case let .helloOK(width, height, _) = reply else {
            Issue.record("no HELLO_OK. server stderr: \(server.lastError)")
            return
        }
        #expect(width > 0 && height > 0)
    }

    @Test func wrongTokenIsRejected() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await handshake(port: server.port, token: ProtocolEncoder.makeToken(), within: 4)
        #expect(reply == nil)
    }

    // MARK: - helpers

    private func setup() throws -> (ADBBridge, String, URL) {
        let adb = try ADBBridge()
        let serial = try #require(try adb.devices().first(where: \.isReady)?.serial)
        let jar = try #require(ServerJar.locate())
        return (adb, serial, jar)
    }

    /// The server may not be listening yet, so a closed connection is retried until the deadline.
    private func handshake(port: Int, token: String, within seconds: Double = 8) async -> ServerPacket? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let packet = await attempt(port: port, token: token) {
                return packet
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func attempt(port: Int, token: String) async -> ServerPacket? {
        await withCheckedContinuation { continuation in
            let connection = Connection(port: UInt16(port), queue: DispatchQueue(label: "smoke"))
            let finished = OSAllocatedUnfairLock(initialState: false)
            let parser = OSAllocatedUnfairLock(initialState: ServerPacketParser())
            @Sendable func finish(_ packet: ServerPacket?) {
                guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: packet)
            }
            connection.onReady = { connection.send(ProtocolEncoder.hello(token: token)) }
            connection.onData = { data in
                if let first = parser.withLock({ try? $0.feed(data) })?.first {
                    finish(first)
                }
            }
            connection.onClosed = { finish(nil) }
            connection.start()
        }
    }
}
