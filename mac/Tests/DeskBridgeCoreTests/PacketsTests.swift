@testable import DeskBridgeCore
import Foundation
import Testing

struct PacketsTests {
    @Test func encodesHello() {
        let token = String(repeating: "a", count: 32)
        let data = ProtocolEncoder.hello(token: token)
        #expect(data.count == 34)
        #expect(Array(data.prefix(2)) == [0x01, 0x01])
        #expect(String(decoding: data.dropFirst(2), as: UTF8.self) == token)
    }

    @Test func encodesEnterAndLeave() {
        let data = ProtocolEncoder.enter(edge: .right, along: 0.5)
        #expect(Array(data) == [0x04, 0x01, 0x3F, 0x00, 0x00, 0x00])
        #expect(Array(ProtocolEncoder.leave()) == [0x06])
        #expect(Array(ProtocolEncoder.enter(edge: .top, along: 0)) == [0x04, 0x02, 0, 0, 0, 0])
        #expect(Array(ProtocolEncoder.enter(edge: .bottom, along: 0)) == [0x04, 0x03, 0, 0, 0, 0])
    }

    @Test func encodesMoveRelBigEndian() {
        let data = ProtocolEncoder.moveRel(dx: 100, dy: -2)
        #expect(Array(data) == [0x11, 0x42, 0xC8, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00])
    }

    @Test func encodesButtonScrollKey() {
        #expect(Array(ProtocolEncoder.button(2, down: true)) == [0x12, 0x02, 0x00])
        #expect(Array(ProtocolEncoder.button(2, down: false)) == [0x12, 0x02, 0x01])
        #expect(ProtocolEncoder.scroll(h: 0, v: -1).count == 9)
        let key = ProtocolEncoder.key(code: 29, down: false, meta: 0x1000)
        #expect(Array(key) == [0x20, 0, 0, 0, 29, 0x01, 0, 0, 0x10, 0x00])
    }

    @Test func tokenIs32HexChars() {
        let token = ProtocolEncoder.makeToken()
        #expect(token.count == 32)
        let allHex = token.allSatisfy { $0.isHexDigit }
        #expect(allHex)
        #expect(token != ProtocolEncoder.makeToken())
    }

    @Test func parsesHelloOKSplitAcrossReads() throws {
        var parser = ServerPacketParser()
        let bytes: [UInt8] = [0x02, 0, 0, 4, 56, 0, 0, 9, 96, 0, 0, 0, 1]
        #expect(try parser.feed(Data(bytes[0 ..< 5])).isEmpty)
        let packets = try parser.feed(Data(bytes[5...]))
        #expect(packets == [.helloOK(width: 1080, height: 2400, rotation: 1)])
    }

    @Test func parsesExitAndPongInOneRead() throws {
        var parser = ServerPacketParser()
        let packets = try parser.feed(Data([0x05, 0x3F, 0x00, 0x00, 0x00, 0xFF]))
        #expect(packets == [.exit(along: 0.5), .pong])
    }

    @Test func encodesText() {
        #expect(Array(ProtocolEncoder.text("ế")) == [0x21, 0, 0, 0, 3, 0xE1, 0xBA, 0xBF])
    }

    @Test func encodesClipboard() {
        #expect(Array(ProtocolEncoder.clipboard("")) == [0x30, 0, 0, 0, 0])
        #expect(Array(ProtocolEncoder.clipboard("é")) == [0x30, 0, 0, 0, 2, 0xC3, 0xA9])
    }

    @Test func parsesClipboardSplitAcrossReads() throws {
        var parser = ServerPacketParser()
        let bytes = Array(ProtocolEncoder.clipboard("tiếng Việt")) + [0xFF]
        #expect(try parser.feed(Data(bytes[0 ..< 3])).isEmpty)
        #expect(try parser.feed(Data(bytes[3 ..< 9])).isEmpty)
        let packets = try parser.feed(Data(bytes[9...]))
        #expect(packets == [.clipboard("tiếng Việt"), .pong])
    }

    @Test func oversizedClipboardThrows() {
        var parser = ServerPacketParser()
        let length = Int32(ProtocolEncoder.maxClipboardBytes + 1)
        let header: [UInt8] = [0x30] + withUnsafeBytes(of: length.bigEndian, Array.init)
        #expect(throws: ProtocolError.clipboardTooLarge(Int(length))) {
            try parser.feed(Data(header))
        }
    }

    @Test func unknownPacketThrows() {
        var parser = ServerPacketParser()
        #expect(throws: ProtocolError.unknownPacket(0x7E)) {
            try parser.feed(Data([0x7E]))
        }
    }
}
