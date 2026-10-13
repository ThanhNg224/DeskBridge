@testable import DeskBridgeCore
import Foundation
import os
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_DEVICE"] != nil))
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
        let packets = await run(port: server.port, token: server.token,
                                afterHello: script.map { Step($0) })
        { packets in
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

    /// Regression: the drawn cursor must never cover the click point, or Android drops the touch
    /// ("Untrusted touch due to occlusion by /2000") and Samsung shows a "not optimised" toast.
    @Test func cursorOverlayDoesNotBlockClicks() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }
        _ = try adb.run(["-s", serial, "logcat", "-c"])

        // ENTER on the left edge, wait for the overlay layer to register, then click and ping.
        let script = [
            Step(ProtocolEncoder.enter(edge: .left, along: 0.5)),
            Step(ProtocolEncoder.moveRel(dx: 300, dy: 0), delay: 0.3),
            Step(ProtocolEncoder.button(1, down: true), delay: 1.5),
            Step(ProtocolEncoder.button(1, down: false), delay: 1.6),
            Step(ProtocolEncoder.leave(), delay: 2.2),
            Step(ProtocolEncoder.ping(), delay: 2.4),
        ]
        let packets = await run(port: server.port, token: server.token, within: 12, afterHello: script) {
            $0.contains(.pong)
        }
        #expect(packets?.contains(.pong) == true)

        let log = try adb.run(["-s", serial, "logcat", "-d"])
        #expect(!log.contains("Untrusted touch due to occlusion by /2000"))
    }

    @Test func pingIsAnswered() async throws {
        let (adb, serial, jar) = try setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let packets = await run(port: server.port, token: server.token, afterHello: [Step(ProtocolEncoder.ping())]) {
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

    /// A packet sent `delay` seconds after HELLO_OK.
    struct Step {
        let data: Data
        let delay: TimeInterval
        init(_ data: Data, delay: TimeInterval = 0) {
            self.data = data
            self.delay = delay
        }
    }

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
        afterHello: [Step],
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
        afterHello: [Step],
        until: @escaping @Sendable ([ServerPacket]) -> Bool
    ) async -> [ServerPacket]? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "smoke")
            let connection = Connection(port: UInt16(port), queue: queue)
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
                    for step in afterHello {
                        queue.asyncAfter(deadline: .now() + step.delay) { connection.send(step.data) }
                    }
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
