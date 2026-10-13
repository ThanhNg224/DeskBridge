import Carbon.HIToolbox
import CoreGraphics
@testable import DeskBridgeCore
import Foundation
import Testing

struct RemoteInputTests {
    private func action(_ event: CapturedEvent, _ edit: (inout Settings.Values) -> Void = { _ in }) -> RemoteAction {
        var prefs = Settings.Values()
        edit(&prefs)
        return RemoteInput.action(for: event, prefs: prefs)
    }

    @Test func movesAreScaledByPointerSpeed() {
        let move = CapturedEvent.move(dx: 3, dy: -1, location: .zero)
        #expect(action(move) == .move(dx: 6, dy: -2)) // default speed is 2
        #expect(action(move) { $0.pointerSpeed = 0.5 } == .move(dx: 1.5, dy: -0.5))
    }

    @Test func leftAndMiddleButtons() {
        #expect(action(.button(.left, down: true)) == .send(ProtocolEncoder.button(1, down: true)))
        #expect(action(.button(.other, down: false)) == .send(ProtocolEncoder.button(4, down: false)))
    }

    @Test func rightClickIsBackOrSecondaryButton() {
        #expect(action(.button(.right, down: true)) == .send(ProtocolEncoder.key(code: 4, down: true, meta: 0)))
        #expect(action(.button(.right, down: false)) { $0.rightClickIsBack = false }
            == .send(ProtocolEncoder.button(2, down: false)))
    }

    @Test func scrollUsesSpeedAndInvert() {
        let scroll = CapturedEvent.scroll(h: 1, v: -2)
        #expect(action(scroll) == .send(ProtocolEncoder.scroll(h: 1, v: -2)))
        #expect(action(scroll) { $0.scrollSpeed = 2; $0.invertScroll = true }
            == .send(ProtocolEncoder.scroll(h: -2, v: 4)))
    }

    @Test func mappedKeysCarryAndroidMeta() {
        let command = CGEventFlags.maskCommand.rawValue
        let key = CapturedEvent.key(code: UInt16(kVK_ANSI_A), down: true, flags: command)
        #expect(action(key) == .send(ProtocolEncoder.key(code: 29, down: true, meta: 0x1000 | 0x2000)))
        #expect(action(key) { $0.commandIsControl = false }
            == .send(ProtocolEncoder.key(code: 29, down: true, meta: 0x10000 | 0x20000)))
    }

    @Test func unmappedKeysAreIgnored() {
        #expect(action(.key(code: UInt16(kVK_Function), down: true, flags: 0)) == .ignore)
    }

    @Test func releaseChordGivesControlBackOnKeyDownOnly() {
        let chord = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        #expect(action(.key(code: UInt16(kVK_Escape), down: true, flags: chord)) == .releaseToMac)
        // The key-up of the chord is a normal Escape release.
        #expect(action(.key(code: UInt16(kVK_Escape), down: false, flags: chord)) != .releaseToMac)
    }
}
