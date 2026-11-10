@testable import DeskBridgeCore
import Testing

struct DevicePickerTests {
    @Test func groupsOnlyUnambiguousMatchingTransports() {
        let usb = AdbDevice(serial: "usb", state: "device", physicalID: "one")
        let wifi = AdbDevice(serial: "1.2.3.4:5555", state: "device", physicalID: "one")
        let unknown = AdbDevice(serial: "other", state: "device")
        #expect(DevicePicker.phones(from: [usb, wifi], preferredSerial: wifi.serial) == [wifi])
        #expect(DevicePicker.phones(from: [usb, wifi, unknown], preferredSerial: nil).count == 2)
        let duplicate = AdbDevice(serial: "usb2", state: "device", physicalID: "one")
        #expect(DevicePicker.phones(from: [usb, wifi, duplicate], preferredSerial: nil).count == 3)
        #expect(DevicePicker.alternate(for: usb.serial, identity: "one", in: [wifi]) == wifi)
        #expect(DevicePicker.alternate(for: usb.serial, identity: nil, in: [wifi]) == nil)
        #expect(DevicePicker.alternate(for: usb.serial, identity: "one", in: [wifi, duplicate]) == nil)
    }

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
