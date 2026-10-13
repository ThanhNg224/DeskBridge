@testable import DeskBridgeCore
import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_DEVICE"] != nil))
struct DeviceSmokeTests {
    @Test func handshakeSucceedsWithToken() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await DeviceHarness.handshake(port: server.port, token: server.token)
        guard case let .helloOK(width, height, _) = reply else {
            Issue.record("no HELLO_OK. server stderr: \(server.lastError)")
            return
        }
        #expect(width > 0 && height > 0)
    }

    @Test func wrongTokenIsRejected() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let reply = await DeviceHarness.handshake(port: server.port, token: ProtocolEncoder.makeToken(), within: 4)
        #expect(reply == nil)
    }

    @Test func enterMoveAndExitRoundTrip() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        // Enter on the left edge at mid height, then push left: the server must hand control back.
        let script = [
            ProtocolEncoder.enter(edge: .left, along: 0.5),
            ProtocolEncoder.moveRel(dx: 80, dy: 0),
            ProtocolEncoder.moveRel(dx: -200, dy: 0),
        ]
        let packets = await DeviceHarness.run(port: server.port, token: server.token,
                                              afterHello: script.map { Step($0) })
        {
            $0.contains { $0.exitAlong != nil }
        }
        guard let exit = packets?.compactMap(\.exitAlong).first else {
            Issue.record("no EXIT. server stderr: \(server.lastError)")
            return
        }
        #expect(abs(exit - 0.5) < 0.01)
    }

    /// Regression: the drawn cursor must never cover the click point, or Android drops the touch
    /// ("Untrusted touch due to occlusion by /2000") and Samsung shows a "not optimised" toast.
    @Test func cursorOverlayDoesNotBlockClicks() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
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
        let packets = await DeviceHarness.run(port: server.port, token: server.token, within: 12,
                                              afterHello: script) { $0.contains(where: \.isPong) }
        #expect(packets?.contains(where: \.isPong) == true)

        let log = try adb.run(["-s", serial, "logcat", "-d"])
        #expect(!log.contains("Untrusted touch due to occlusion by /2000"))
    }

    @Test func pingIsAnswered() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let packets = await DeviceHarness.run(port: server.port, token: server.token,
                                              afterHello: [Step(ProtocolEncoder.ping())])
        {
            $0.contains(where: \.isPong)
        }
        #expect(packets?.contains(where: \.isPong) == true)
    }

    /// Round-trip of PING/PONG over adb forward: an upper bound for one-way input latency x2.
    @Test func pingRoundTripLatency() async throws {
        let (adb, serial, jar) = try DeviceHarness.setup()
        let server = try adb.launchServer(serial: serial, jar: jar)
        defer { server.terminate() }

        let samples = await DeviceHarness.measureRoundTrips(port: server.port, token: server.token, count: 300)
        let sorted = try #require(samples).sorted()
        let p50 = sorted[sorted.count / 2] * 1000
        let p95 = sorted[Int(Double(sorted.count) * 0.95)] * 1000
        try print(String(format: "PING RTT over adb: p50 %.2f ms, p95 %.2f ms, max %.2f ms",
                         p50, p95, #require(sorted.last) * 1000))
        #expect(p95 < DeviceHarness.maxP95Milliseconds)
    }
}
