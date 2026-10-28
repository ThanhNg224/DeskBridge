import CoreGraphics
@testable import DeskBridgeCore
import Foundation
import os
import Testing

struct KeyRoutingTests {
    private let a: UInt16 = 0, space: UInt16 = 49, backspace: UInt16 = 51, leftArrow: UInt16 = 123
    private let ime = KeyboardState(imeActive: true, ready: true, composing: false)

    @Test func textKeysGoToTheMacInputMethod() {
        #expect(KeyRouting.deliversToMac(keyCode: a, flags: [], state: ime))
        #expect(KeyRouting.deliversToMac(keyCode: a, flags: .maskShift, state: ime))
        #expect(KeyRouting.deliversToMac(keyCode: space, flags: [], state: ime))
    }

    @Test func otherKeysGoToThePhoneUnlessAWordIsBeingComposed() {
        #expect(!KeyRouting.deliversToMac(keyCode: backspace, flags: [], state: ime))
        #expect(!KeyRouting.deliversToMac(keyCode: leftArrow, flags: [], state: ime))
        var composing = ime
        composing.composing = true
        #expect(KeyRouting.deliversToMac(keyCode: backspace, flags: [], state: composing))
        #expect(KeyRouting.deliversToMac(keyCode: leftArrow, flags: [], state: composing))
    }

    @Test func shortcutsAndTheReleaseChordNeverGoToTheMac() {
        var composing = ime
        composing.composing = true
        for flags: CGEventFlags in [.maskCommand, .maskControl, [.maskControl, .maskAlternate, .maskCommand]] {
            #expect(!KeyRouting.deliversToMac(keyCode: a, flags: flags, state: ime))
            #expect(!KeyRouting.deliversToMac(keyCode: a, flags: flags, state: composing))
        }
    }

    @Test func nothingGoesToTheMacWithoutAnInputMethodOrAReadyWindow() {
        #expect(!KeyRouting.deliversToMac(keyCode: a, flags: [], state: KeyboardState(imeActive: false, ready: true)))
        #expect(!KeyRouting.deliversToMac(keyCode: a, flags: [], state: KeyboardState(imeActive: true, ready: false)))
        #expect(!KeyRouting.deliversToMac(
            keyCode: backspace, flags: [], state: KeyboardState(imeActive: true, ready: false, composing: true)
        ))
    }

    @Test @MainActor func committingMarkedTextPreservesTheComposedWord() {
        let keyboard = KeyboardStateBox()
        let composer = ComposerView(keyboard: keyboard)
        let received = OSAllocatedUnfairLock(initialState: [String]())
        composer.onText = { text in received.withLock { $0.append(text) } }
        composer.setMarkedText("tiếng Việt", selectedRange: NSRange(location: 0, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
        #expect(keyboard.read().composing)
        composer.unmarkText()
        composer.unmarkText()
        #expect(received.withLock { $0 } == ["tiếng Việt"])
        #expect(!keyboard.read().composing)
    }
}
