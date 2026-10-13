import Foundation

public enum PacketType: UInt8, Sendable {
    case hello = 0x01
    case helloOK = 0x02
    case enter = 0x04
    case exit = 0x05
    case leave = 0x06
    case mouseMoveRel = 0x11
    case mouseButton = 0x12
    case mouseScroll = 0x13
    case keyEvent = 0x20
    case clipboard = 0x30
    case ping = 0xFE
    case pong = 0xFF
}

/// Edge of the Android display on which the pointer appears.
public enum AndroidEdge: UInt8, Sendable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
}

public enum ProtocolEncoder {
    public static let version: UInt8 = 1
    public static let tokenLength = 32
    /// Largest clipboard text (UTF-8 bytes) either side sends.
    public static let maxClipboardBytes = 1 << 20

    /// 16 random bytes as 32 lowercase hex characters.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 16)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    public static func hello(token: String) -> Data {
        var data = Data([PacketType.hello.rawValue, version])
        data.append(contentsOf: Array(token.utf8))
        return data
    }

    public static func enter(edge: AndroidEdge, along: Float) -> Data {
        var data = Data([PacketType.enter.rawValue, edge.rawValue])
        data.appendBE(along)
        return data
    }

    public static func leave() -> Data {
        Data([PacketType.leave.rawValue])
    }

    public static func moveRel(dx: Float, dy: Float) -> Data {
        var data = Data([PacketType.mouseMoveRel.rawValue])
        data.appendBE(dx)
        data.appendBE(dy)
        return data
    }

    /// `button` is an Android MotionEvent.BUTTON_* bit (1 primary, 2 secondary, 4 tertiary).
    public static func button(_ button: UInt8, down: Bool) -> Data {
        Data([PacketType.mouseButton.rawValue, button, down ? 0 : 1])
    }

    public static func scroll(h: Float, v: Float) -> Data {
        var data = Data([PacketType.mouseScroll.rawValue])
        data.appendBE(h)
        data.appendBE(v)
        return data
    }

    /// `code` and `meta` are Android KeyEvent values.
    public static func key(code: Int32, down: Bool, meta: Int32) -> Data {
        var data = Data([PacketType.keyEvent.rawValue])
        data.appendBE(code)
        data.append(down ? 0 : 1)
        data.appendBE(meta)
        return data
    }

    /// Text of at most `maxClipboardBytes` UTF-8 bytes. Empty means "share the clipboard this visit, nothing new".
    public static func clipboard(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var data = Data([PacketType.clipboard.rawValue])
        data.appendBE(Int32(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    public static func ping() -> Data {
        Data([PacketType.ping.rawValue])
    }
}

public enum ServerPacket: Equatable, Sendable {
    case helloOK(width: Int32, height: Int32, rotation: Int32)
    case exit(along: Float)
    case clipboard(String)
    case pong
}

public enum ProtocolError: Error, Equatable {
    case unknownPacket(UInt8)
    case clipboardTooLarge(Int)
}

/// Incremental parser for the Android→Mac stream; tolerates packets split across reads.
public struct ServerPacketParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ServerPacket] {
        buffer.append(contentsOf: data)
        var packets: [ServerPacket] = []
        while let type = buffer.first {
            switch PacketType(rawValue: type) {
            case .helloOK:
                guard buffer.count >= 13 else { return packets }
                packets.append(.helloOK(
                    width: Int32(bitPattern: word(at: 1)),
                    height: Int32(bitPattern: word(at: 5)),
                    rotation: Int32(bitPattern: word(at: 9))
                ))
                buffer.removeFirst(13)
            case .exit:
                guard buffer.count >= 5 else { return packets }
                packets.append(.exit(along: Float(bitPattern: word(at: 1))))
                buffer.removeFirst(5)
            case .clipboard:
                guard buffer.count >= 5 else { return packets }
                let length = Int(Int32(bitPattern: word(at: 1)))
                guard length >= 0, length <= ProtocolEncoder.maxClipboardBytes else {
                    throw ProtocolError.clipboardTooLarge(length)
                }
                guard buffer.count >= 5 + length else { return packets }
                packets.append(.clipboard(String(decoding: buffer[5 ..< 5 + length], as: UTF8.self)))
                buffer.removeFirst(5 + length)
            case .pong:
                packets.append(.pong)
                buffer.removeFirst(1)
            default:
                throw ProtocolError.unknownPacket(type)
            }
        }
        return packets
    }

    private func word(at index: Int) -> UInt32 {
        (UInt32(buffer[index]) << 24) | (UInt32(buffer[index + 1]) << 16)
            | (UInt32(buffer[index + 2]) << 8) | UInt32(buffer[index + 3])
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: Int32) {
        appendBE(UInt32(bitPattern: value))
    }

    mutating func appendBE(_ value: Float) {
        appendBE(value.bitPattern)
    }
}
