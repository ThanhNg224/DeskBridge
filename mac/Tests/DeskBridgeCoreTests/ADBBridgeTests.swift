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

    @Test func parsesModelFromLongListing() {
        let output = """
        List of devices attached
        RF8NA2EZKZK            device usb:17956864X product:r7nsxx model:SM_N770F device:r7 transport_id:29
        emulator-5554          device product:sdk model:sdk_gphone64_arm64 device:emu64a transport_id:3

        """
        let devices = ADBBridge.parseDevices(output)
        #expect(devices.map(\.model) == ["SM N770F", "sdk gphone64 arm64"])
        #expect(devices[0].displayName == "SM N770F")
        #expect(AdbDevice(serial: "X", state: "device").displayName == "X")
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

    @Test func isWirelessDistinguishesUsbAndWifi() {
        let usbDevice = AdbDevice(serial: "RF8NA2EZKZK", state: "device")
        #expect(!usbDevice.isWireless)

        let wifiDevice = AdbDevice(serial: "192.168.1.50:5555", state: "device")
        #expect(wifiDevice.isWireless)
    }

    @Test func parseIPExtractsWlanAddress() {
        let routeOutput = """
        192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.120
        default via 192.168.1.1 dev wlan0
        """
        #expect(ADBBridge.parseIP(from: routeOutput) == "192.168.1.120")

        let addrOutput = """
        inet 192.168.1.125/24 brd 192.168.1.255 scope global wlan0
        """
        #expect(ADBBridge.parseIP(from: addrOutput) == "192.168.1.125")

        let emptyOutput = ""
        #expect(ADBBridge.parseIP(from: emptyOutput) == nil)
    }

    @Test func parseConnectOutputDetectsErrors() {
        let successOutput = "connected to 192.168.1.50:5555\n"
        let alreadyConnected = "already connected to 192.168.1.50:5555\n"
        let failureOutput = "failed to connect to 192.168.1.50:5555: Connection refused\n"
        let unableOutput = "unable to connect to 192.168.1.50:5555: Connection timed out\n"

        #expect(ADBBridge.isConnectSuccessful(output: successOutput))
        #expect(ADBBridge.isConnectSuccessful(output: alreadyConnected))
        #expect(!ADBBridge.isConnectSuccessful(output: failureOutput))
        #expect(!ADBBridge.isConnectSuccessful(output: unableOutput))
    }
}
