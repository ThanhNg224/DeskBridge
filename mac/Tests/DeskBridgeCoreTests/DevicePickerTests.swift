@testable import DeskBridgeCore
import Testing

struct DevicePickerTests {
    private let ready = AdbDevice(serial: "A", state: "device")
    private let second = AdbDevice(serial: "B", state: "device")
    private let unauthorized = AdbDevice(serial: "C", state: "unauthorized")

    @Test func nothingAttached() {
        #expect(DevicePicker.pick(from: []) == .none)
    }

    @Test func onlyAnUnusableDevice() {
        #expect(DevicePicker.pick(from: [unauthorized]) == .notReady(unauthorized))
    }

    @Test func theOnlyReadyDeviceIsUsedEvenAfterAnUnusableOne() {
        #expect(DevicePicker.pick(from: [unauthorized, ready]) == .ready(ready))
    }

    @Test func severalReadyDevicesNeedAChoice() {
        #expect(DevicePicker.pick(from: [unauthorized, ready, second]) == .choose([ready, second]))
    }

    @Test func thePreferredDeviceWinsWhenReady() {
        #expect(DevicePicker.pick(from: [ready, second], preferredSerial: "B") == .ready(second))
        let missing = AdbDevice(serial: "gone", state: "offline")
        #expect(DevicePicker.pick(from: [ready, second], preferredSerial: "gone") == .notReady(missing))
        #expect(DevicePicker.pick(from: [ready], preferredSerial: "gone") == .notReady(missing))
        #expect(DevicePicker.pick(from: [], preferredSerial: "gone") == .notReady(missing))
    }

    @Test func unauthorizedSelectionDoesNotFallBackToAnotherPhone() {
        #expect(DevicePicker.pick(from: [ready, unauthorized], preferredSerial: "C") == .notReady(unauthorized))
    }
}
