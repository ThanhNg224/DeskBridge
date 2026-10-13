@testable import DeskBridgeCore
import Foundation
import os
import Testing

extension ServerPacket {
    var isHelloOK: Bool {
        if case .helloOK = self {
            true
        } else {
            false
        }
    }

    var isPong: Bool {
        if case .pong = self {
            true
        } else {
            false
        }
    }

    var exitAlong: Float? {
        if case let .exit(along) = self {
            along
        } else {
            nil
        }
    }
}

/// A packet sent `delay` seconds after HELLO_OK.
struct Step {
    let data: Data
    let delay: TimeInterval
    init(_ data: Data, delay: TimeInterval = 0) {
        self.data = data
        self.delay = delay
    }
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

enum DeviceHarness {
    /// ANDROID_SERIAL when set (must be listed and ready), else the first ready device.
    static func setup() throws -> (ADBBridge, String, URL) {
        let adb = try ADBBridge()
        let devices = try adb.devices()
        let serial: String
        if let wanted = ProcessInfo.processInfo.environment["ANDROID_SERIAL"] {
            guard devices.contains(where: { $0.serial == wanted && $0.isReady }) else {
                throw HarnessError(description: "ANDROID_SERIAL=\(wanted) is not a ready device in the adb list")
            }
            serial = wanted
        } else {
            guard let first = devices.first(where: \.isReady)?.serial else {
                throw HarnessError(description: "no ready adb device")
            }
            serial = first
        }
        guard let jar = ServerJar.locate() else {
            throw HarnessError(description: "server jar not found")
        }
        return (adb, serial, jar)
    }

    /// Upper bound for the ping latency p95, in ms (DESKBRIDGE_MAX_P95_MS, default 25).
    static var maxP95Milliseconds: Double {
        ProcessInfo.processInfo.environment["DESKBRIDGE_MAX_P95_MS"].flatMap(Double.init) ?? 25
    }

    /// First packet after HELLO, or nil if the server never answers (e.g. rejected token).
    static func handshake(port: Int, token: String, within seconds: Double = 8) async -> ServerPacket? {
        await run(port: port, token: token, within: seconds, afterHello: []) { _ in true }?.first
    }

    /// Connects (retrying while the server starts), sends HELLO, then `afterHello` once HELLO_OK arrived,
    /// and collects every packet (HELLO_OK included) until `until` is satisfied. Returns nil on timeout or rejection.
    static func run(
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

    static func attempt(
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
                    let hadHello = state.packets.contains(where: \.isHelloOK)
                    state.packets += (try? state.parser.feed(data)) ?? []
                    let hasHello = state.packets.contains(where: \.isHelloOK)
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

    static func measureRoundTrips(port: Int, token: String, count: Int) async -> [Double]? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let samples = await roundTrips(port: port, token: token, count: count) {
                return samples
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    static func roundTrips(port: Int, token: String, count: Int) async -> [Double]? {
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
