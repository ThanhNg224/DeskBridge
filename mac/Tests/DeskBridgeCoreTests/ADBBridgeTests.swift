@testable import DeskBridgeCore
import Testing

struct ADBBridgeTests {
    @Test func parsesDeviceList() {
        let output = """
        * daemon started successfully *
        List of devices attached
        emulator-5554\tdevice
        RFC840\tunauthorized
        192.168.1.50:5555\tdevice
        R5CT\toffline

        """
        let devices = ADBBridge.parseDevices(output)
        #expect(devices.map(\.serial) == ["emulator-5554", "RFC840", "192.168.1.50:5555", "R5CT"])
        #expect(devices.filter(\.isReady).map(\.serial) == ["emulator-5554", "192.168.1.50:5555"])
    }

    @Test func parsesEmptyList() {
        #expect(ADBBridge.parseDevices("List of devices attached\n\n").isEmpty)
    }

    @Test func findsStaleForwards() {
        let output = """
        RF8NA2EZKZK tcp:57534 localabstract:deskbridge-59cfef45
        RF8NA2EZKZK tcp:6000 localabstract:other
        OTHER tcp:57535 localabstract:deskbridge-aaaaaaaa

        """
        #expect(ADBBridge.staleForwardPorts(in: output, serial: "RF8NA2EZKZK") == [57534])
    }

    @Test func parsesForwardPort() throws {
        #expect(try ADBBridge.parseForwardPort("54321\n") == 54321)
        #expect(throws: ADBError.self) { try ADBBridge.parseForwardPort("error: closed") }
    }
}
