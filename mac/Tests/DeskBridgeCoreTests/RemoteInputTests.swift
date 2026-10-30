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

    @Test func shortcutsKeepTheirAndroidKeyUntilRelease() {
        let keys: [(Int, Int32)] = [(kVK_ANSI_H, 3), (kVK_ANSI_B, 4), (kVK_ANSI_R, 187),
                                    (kVK_ANSI_L, 223), (kVK_UpArrow, 24), (kVK_DownArrow, 25),
                                    (kVK_RightArrow, 221), (kVK_LeftArrow, 220), (kVK_ANSI_N, 83),
                                    (kVK_ANSI_M, 164), (kVK_ANSI_P, 85)]
        var shortcuts = ShortcutKeys()
        for (mac, android) in keys {
            let code = UInt16(mac)
            #expect(shortcuts.route(code: code, down: true, flags: .maskAlternate) == android)
            #expect(shortcuts.route(code: code, down: false, flags: []) == android)
            #expect(action(.androidKey(code: android, down: true))
                == .send(ProtocolEncoder.key(code: android, down: true, meta: 0)))
            #expect(action(.androidKey(code: android, down: false))
                == .send(ProtocolEncoder.key(code: android, down: false, meta: 0)))
        }
        #expect(shortcuts.route(code: UInt16(kVK_ANSI_H), down: true, flags: [.maskAlternate, .maskCommand]) == nil)
        #expect(shortcuts.route(code: UInt16(kVK_ANSI_H), down: true, flags: []) == nil)
    }

    @Test func appSwitcherHoldsAltAcrossRepeatedTabPresses() {
        var switcher = AppSwitcher()
        let altDown = AppSwitcher.Key(code: 57, down: true, meta: 0x12)
        let tabDown = AppSwitcher.Key(code: 61, down: true, meta: 0x12)
        let tabUp = AppSwitcher.Key(code: 61, down: false, meta: 0x12)
        let altUp = AppSwitcher.Key(code: 57, down: false, meta: 0)
        #expect(switcher.tab(down: true, flags: .maskAlternate) == [altDown, tabDown])
        #expect(switcher.tab(down: true, flags: .maskAlternate) == [])
        #expect(switcher.tab(down: false, flags: .maskAlternate) == [tabUp])
        #expect(switcher.tab(down: true, flags: .maskAlternate) == [tabDown])
        #expect(switcher.tab(down: false, flags: .maskAlternate) == [tabUp])
        #expect(switcher.modifiersChanged([]) == [altUp])
        #expect(switcher.modifiersChanged([]).isEmpty)
        #expect(action(.switchKey(code: 61, down: true, meta: 0x12))
            == .send(ProtocolEncoder.key(code: 61, down: true, meta: 0x12)))
    }

    @Test func appSwitcherHandlesReleasingOptionBeforeTab() {
        var switcher = AppSwitcher()
        #expect(switcher.tab(down: true, flags: []) == nil)
        #expect(switcher.tab(down: true, flags: [.maskAlternate, .maskCommand]) == nil)
        #expect(switcher.tab(down: true, flags: .maskAlternate)?.count == 2)
        #expect(switcher.modifiersChanged([]) == [AppSwitcher.Key(code: 57, down: false, meta: 0)])
        #expect(switcher.tab(down: false, flags: []) == [AppSwitcher.Key(code: 61, down: false, meta: 0)])
        #expect(switcher.tab(down: false, flags: []) == nil)
    }
}
