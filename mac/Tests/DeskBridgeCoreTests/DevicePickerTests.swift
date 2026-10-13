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

    @Test func firstReadyDeviceWinsEvenAfterAnUnusableOne() {
        #expect(DevicePicker.pick(from: [unauthorized, ready, second]) == .ready(ready))
    }
}
