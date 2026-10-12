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

    @Test func enterMoveAndExitRoundTrip() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        // Enter on the left edge at mid height, then push left: the server must hand control back.
        let script = [
            ProtocolEncoder.enter(edge: .left, along: 0.5),
            ProtocolEncoder.moveRel(dx: 80, dy: 0),
            ProtocolEncoder.moveRel(dx: -200, dy: 0),
        ]
        let packets = await run(port: server.port, token: server.token, afterHello: script) { packets in
            packets.contains {
                if case .exit = $0 {
                    true
                } else {
                    false
                }
            }
        }
        guard let exit = packets?.compactMap({ packet -> Float? in
            if case let .exit(along) = packet {
                along
            } else {
                nil
            }
        }).first else {
            Issue.record("no EXIT. server stderr: \(server.lastError)")
            return
        }
        #expect(abs(exit - 0.5) < 0.01)
    }

    @Test func pingIsAnswered() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let packets = await run(port: server.port, token: server.token, afterHello: [ProtocolEncoder.ping()]) {
            $0.contains(.pong)
        }
        #expect(packets?.contains(.pong) == true)
    }

    /// Round-trip of PING/PONG over adb forward: an upper bound for one-way input latency x2.
    @Test func pingRoundTripLatency() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let samples = await measureRoundTrips(port: server.port, token: server.token, count: 300)
        let sorted = try #require(samples).sorted()
        let p50 = sorted[sorted.count / 2] * 1000
        let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
        try print(String(format: "PING RTT over adb: p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                         p50, p95, #require(sorted.last) * 1000))
        #expect(p95 < 25)
    }

    // MARK: - helpers

    private func setup() throws -> (ADBBridge, String, URL) {
        let adb = try ADBBridge()
        let serial = try #require(try adb.devices().first(where: \.isReady)?.serial)
        let jar = try #require(ServerJar.locate())
        return (adb, serial, jar)
    }

    /// First packet after HELLO, or nil if the server never answers (e.g. rejected token).
    private func handshake(port: Int, token: String, within seconds: Double = 8) async -> ServerPacket? {
        await run(port: port, token: token, within: seconds, afterHello: []) { _ in true }?.first
    }

    /// Connects (retrying while the server starts), sends HELLO, then `afterHello` once HELLO_OK arrived,
    /// and collects every packet (HELLO_OK included) until `until` is satisfied. Returns nil on timeout or rejection.
    private func run(
        port: Int,
        token: String,
        within seconds: Double = 8,
        afterHello: [Data],
        until: @escaping @Sendable ([ServerPacket]) -> Bool
    ) async -> [ServerPacket]? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let packets = await attempt(port: port, token: token, afterHello: afterHello, until: until) {
                return packets
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func attempt(
        port: Int,
        token: String,
        afterHello: [Data],
        until: @escaping @Sendable ([ServerPacket]) -> Bool
    ) async -> [ServerPacket]? {
        await withCheckedContinuation { continuation in
            let connection = Connection(port: UInt16(port), queue: DispatchQueue(label: "smoke"))
            let finished = OSAllocatedUnfairLock(initialState: false)
            let state = OSAllocatedUnfairLock(initialState: (parser: ServerPacketParser(), packets: [ServerPacket]()))
            @Sendable func finish(_ packets: [ServerPacket]?) {
                guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: packets)
            }
            connection.onReady = { connection.send(ProtocolEncoder.hello(token: token)) }
            connection.onData = { data in
                let (packets, sawHello) = state.withLock { state -> ([ServerPacket], Bool) in
                    let hadHello = state.packets.contains {
                        if case .helloOK = $0 {
                            true
                        } else {
                            false
                        }
                    }
                    state.packets += (try? state.parser.feed(data)) ?? []
                    let hasHello = state.packets.contains {
                        if case .helloOK = $0 {
                            true
                        } else {
                            false
                        }
                    }
                    return (state.packets, !hadHello && hasHello)
                }
                if sawHello {
                    afterHello.forEach { connection.send($0) }
                }
                if !packets.isEmpty, until(packets) {
                    finish(packets)
                }
            }
            connection.onClosed = { finish(nil) }
            connection.start()
        }
    }

    private func measureRoundTrips(port: Int, token: String, count: Int) async -> [Double]? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let samples = await roundTrips(port: port, token: token, count: count) {
                return samples
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func roundTrips(port: Int, token: String, count: Int) async -> [Double]? {
        await withCheckedContinuation { continuation in
            let connection = Connection(port: UInt16(port), queue: DispatchQueue(label: "latency"))
            let finished = OSAllocatedUnfairLock(initialState: false)
            let state = OSAllocatedUnfairLock(initialState: (
                parser: ServerPacketParser(), sentAt: Date(), samples: [Double]()
            ))
            @Sendable func finish(_ samples: [Double]?) {
                guard finished.withLock({ let was = $0; $0 = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: samples)
            }
            connection.onReady = { connection.send(ProtocolEncoder.hello(token: token)) }
            connection.onData = { data in
                let action: (send: Bool, done: [Double]?) = state.withLock { state in
                    var send = false
                    for packet in (try? state.parser.feed(data)) ?? [] {
                        switch packet {
                        case .helloOK:
                            send = true
                        case .pong:
                            state.samples.append(Date().timeIntervalSince(state.sentAt))
                            if state.samples.count >= count {
                                return (false, state.samples)
                            }
                            send = true
                        default:
                            break
                        }
                    }
                    if send {
                        state.sentAt = Date()
                    }
                    return (send, nil)
                }
                if let done = action.done {
                    finish(done)
                } else if action.send {
                    connection.send(ProtocolEncoder.ping())
                }
            }
            connection.onClosed = { finish(nil) }
            connection.start()
        }
    }
}
