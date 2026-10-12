import Carbon.HIToolbox
import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct KeyMapperTests {
    @Test func mapsLettersDigitsAndControls() {
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_A)) == 29)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_S)) == 47) // not SOFT_LEFT(1)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_Z)) == 54)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_ANSI_0)) == 7)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Return)) == 66)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Delete)) == 67)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Escape)) == 111)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_LeftArrow)) == 21)
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_F1)) == 131)
    }

    @Test func unmappedKeysAreDropped() {
        #expect(KeyMapper.androidKeyCode(forMacKeyCode: UInt16(kVK_Function)) == nil)
    }

    @Test func tableHasNoDuplicateAndroidCodes() {
        let codes = KeyMapper.table.values
        #expect(Set(codes).count == codes.count)
    }

    @Test func commandBecomesControl() {
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskCommand.rawValue) == 0x1000 | 0x2000)
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskShift.rawValue) == 0x1 | 0x40)
        #expect(KeyMapper.androidMeta(forFlags: CGEventFlags.maskAlternate.rawValue) == 0x2 | 0x10)
        #expect(KeyMapper.androidMeta(forFlags: 0) == 0)
    }

    @Test func releaseChord() {
        let chord = CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
        #expect(KeyMapper.isReleaseChord(keyCode: UInt16(kVK_Escape), flags: chord))
        #expect(!KeyMapper.isReleaseChord(keyCode: UInt16(kVK_Escape), flags: CGEventFlags.maskCommand.rawValue))
        #expect(!KeyMapper.isReleaseChord(keyCode: UInt16(kVK_ANSI_A), flags: chord))
    }
}
