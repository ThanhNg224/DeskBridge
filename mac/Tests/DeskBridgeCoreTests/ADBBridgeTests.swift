@testable import DeskBridgeCore
import Foundation
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
        #expect(AdbDevice(serial: "adb-phone-random._adb-tls-connect._tcp", state: "device").isWireless)
        #expect(AdbDevice(serial: "adb-phone._adb._tcp", state: "device").isWireless)
        #expect(!AdbDevice(serial: "adb-phone._adb-tls-pairing._tcp", state: "device").isWireless)
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

    @Test func parseIPIgnoresOtherInterfacesAndInvalidAddresses() {
        let mixed = """
        default dev rmnet_data0 src 10.0.0.2
        10.0.0.0/24 dev tun0 src 10.0.0.3
        192.168.1.0/24 dev wlan0 src 192.168.1.120
        """
        #expect(ADBBridge.parseIP(from: mixed) == "192.168.1.120")
        #expect(ADBBridge.parseIP(from: "default dev rmnet_data0 src 10.0.0.2") == nil)
        #expect(ADBBridge.parseIP(from: "default dev wlan0 src 192.168.1.256") == nil)
        #expect(ADBBridge.parseIP(from: "inet 192.168.1.256/24 scope global wlan0") == nil)
    }

    @Test func validatesWirelessTarget() throws {
        #expect(try ADBBridge.wirelessTarget(ip: " \n192.168.001.010\t", port: 5555) == "192.168.1.10:5555")
        #expect(try ADBBridge.wirelessTarget(ip: "0.0.0.0", port: 1) == "0.0.0.0:1")
        #expect(try ADBBridge.wirelessTarget(ip: "255.255.255.255", port: 65535) == "255.255.255.255:65535")
        for ip in [
            "",
            "1.2.3",
            "1.2.3.4.5",
            ".1.2.3",
            "1.2.3.",
            "1.2.3.256",
            "-1.2.3.4",
            "+1.2.3.4",
            "１.2.3.4",
            "1.2. 3.4",
            "host.local",
            "1.2.3.4:5555",
        ] {
            #expect(throws: ADBError.self) { try ADBBridge.wirelessTarget(ip: ip, port: 5555) }
        }
        for port in [-1, 0, 65536, Int.max] {
            #expect(throws: ADBError.self) { try ADBBridge.wirelessTarget(ip: "1.2.3.4", port: port) }
        }
    }

    @Test func deviceIPUsesWifiRouteThenAddressFallback() throws {
        let route = "-s USB shell ip route"
        let addr = "-s USB shell ip -f inet addr show wlan0"
        let fixture = try FakeADB(responses: [
            (route, "default dev rmnet_data0 src 10.0.0.2", 0),
            (addr, "inet 192.168.1.125/24 scope global wlan0", 0),
        ])
        defer { fixture.remove() }
        #expect(try fixture.bridge.deviceIP(serial: "USB") == "192.168.1.125")
        #expect(try fixture.commands() == [route, addr])
    }

    @Test func switchToWirelessRunsRouteTcpipAndConnectInOrder() async throws {
        let fixture = try FakeADB(responses: [
            ("-s USB shell ip route", "192.168.1.0/24 dev wlan0 src 192.168.1.120", 0),
            ("-s USB tcpip 5555", "restarting in TCP mode port: 5555", 0),
            ("connect 192.168.1.120:5555", "connected to 192.168.1.120:5555", 0),
            ("devices -l", "192.168.1.120:5555 device", 0),
        ])
        defer { fixture.remove() }
        #expect(try await fixture.bridge.switchToWireless(serial: "USB") == "192.168.1.120:5555")
        #expect(try fixture.commands() == [
            "-s USB shell ip route", "-s USB tcpip 5555", "connect 192.168.1.120:5555", "devices -l",
        ])
    }

    @Test func noWifiAddressStopsBeforeTcpip() async throws {
        let fixture = try FakeADB(responses: [
            ("-s USB shell ip route", "route failed", 1),
            ("-s USB shell ip -f inet addr show wlan0", "", 0),
        ])
        defer { fixture.remove() }
        do {
            _ = try await fixture.bridge.switchToWireless(serial: "USB")
            Issue.record("Expected noWifiIPFound")
        } catch ADBError.noWifiIPFound {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try fixture.commands() == [
            "-s USB shell ip route", "-s USB shell ip -f inet addr show wlan0",
        ])
    }

    @Test func invalidInputsNeverInvokeADB() async throws {
        let fixture = try FakeADB(responses: [])
        defer { fixture.remove() }
        await #expect(throws: ADBError.self) { try await fixture.bridge.connectWireless(ip: "host.local") }
        await #expect(throws: ADBError.self) { try await fixture.bridge.connectWireless(ip: "1.2.3.4", port: 0) }
        await #expect(throws: ADBError.self) { try await fixture.bridge.switchToWireless(serial: "USB", port: 65536) }
        #expect(try fixture.commands().isEmpty)
    }

    @Test func tcpipFailureStopsBeforeConnect() async throws {
        let fixture = try FakeADB(responses: [
            ("-s USB shell ip route", "default dev wlan0 src 192.168.1.120", 0),
            ("-s USB tcpip 5555", "error: closed", 1),
        ])
        defer { fixture.remove() }
        do {
            _ = try await fixture.bridge.switchToWireless(serial: "USB")
            Issue.record("Expected commandFailed")
        } catch ADBError.commandFailed {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(try fixture.commands().count == 2)
    }

    @Test func connectNormalizesAddressAndDisconnects() async throws {
        let fixture = try FakeADB(responses: [
            ("connect 192.168.1.10:5555", "already connected to 192.168.1.10:5555", 0),
            ("devices -l", "192.168.1.10:5555 device", 0),
            ("disconnect 192.168.1.10:5555", "disconnected 192.168.1.10:5555", 0),
        ])
        defer { fixture.remove() }
        let target = try await fixture.bridge.connectWireless(ip: " 192.168.001.010 \n")
        #expect(target == "192.168.1.10:5555")
        #expect(try fixture.bridge.disconnectWireless(serial: target).contains("disconnected"))
        #expect(try fixture.commands() == ["connect 192.168.1.10:5555", "devices -l", "disconnect 192.168.1.10:5555"])
    }

    @Test func connectSurfacesOutputAndProcessFailures() async throws {
        for status: Int32 in [0, 1] {
            let fixture = try FakeADB(responses: [("connect 1.2.3.4:5555", "failed to connect", status)])
            defer { fixture.remove() }
            do {
                _ = try await fixture.bridge.connectWireless(ip: "1.2.3.4")
                Issue.record("Expected connection failure")
            } catch ADBError.wirelessConnectionFailed {
                #expect(status == 0)
            } catch ADBError.commandFailed {
                #expect(status == 1)
            } catch { Issue.record("Unexpected error: \(error)") }
            #expect(try fixture.commands() == ["connect 1.2.3.4:5555"])
        }
    }

    @Test func endpointClassificationExcludesMDNS() {
        #expect(ADBBridge.wirelessEndpoint(serial: "192.168.1.10:5555")?.ip == "192.168.1.10")
        #expect(ADBBridge.wirelessEndpoint(serial: "adb-phone._adb-tls-connect._tcp") == nil)
        #expect(ADBBridge.wirelessEndpoint(serial: "USB") == nil)
        #expect(ADBBridge.wirelessEndpoint(serial: "host.local:5555") == nil)
    }

    @Test func waitsForExactTargetToBecomeReady() async throws {
        let fixture = try FakeADB(responses: [
            ("connect 1.2.3.4:5555", "connected to 1.2.3.4:5555", 0),
        ], scripts: [("devices -l", """
        if [ -f "$0.ready" ]; then echo '1.2.3.4:5555 device'; else
          touch "$0.ready"; echo 'OTHER device'; echo '1.2.3.4:5555 offline'
        fi
        """)])
        defer { fixture.remove() }
        #expect(try await fixture.bridge.connectWireless(ip: "1.2.3.4") == "1.2.3.4:5555")
        #expect(try fixture.commands() == ["connect 1.2.3.4:5555", "devices -l", "connect 1.2.3.4:5555", "devices -l"])
    }

    @Test func unrelatedReadyDeviceNeverCompletesWirelessPreparation() async throws {
        let fixture = try FakeADB(responses: [
            ("connect 1.2.3.4:5555", "connected to 1.2.3.4:5555", 0),
            ("devices -l", "OTHER device\n1.2.3.4:5555 unauthorized", 0),
        ])
        defer { fixture.remove() }
        do {
            _ = try await fixture.bridge.withOperation(ADBOperation(timeout: 0.8)).connectWireless(ip: "1.2.3.4")
            Issue.record("Expected wirelessDeviceNotReady")
        } catch let ADBError.wirelessDeviceNotReady(target) {
            #expect(target == "1.2.3.4:5555")
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(try fixture.commands() == ["connect 1.2.3.4:5555", "devices -l"])
    }

    @Test func retriesConnectionWhileTCPIPStarts() async throws {
        let fixture = try FakeADB(responses: [
            ("-s USB shell ip route", "default dev wlan0 src 1.2.3.4", 0),
            ("-s USB tcpip 5555", "restarting", 0),
            ("devices -l", "1.2.3.4:5555 device", 0),
        ], scripts: [("connect 1.2.3.4:5555", """
        if [ -f "$0.ready" ]; then echo 'connected to 1.2.3.4:5555'; else
          touch "$0.ready"; echo 'failed to connect'; exit 1
        fi
        """)])
        defer { fixture.remove() }
        #expect(try await fixture.bridge.switchToWireless(serial: "USB") == "1.2.3.4:5555")
        #expect(try fixture.commands() == [
            "-s USB shell ip route",
            "-s USB tcpip 5555",
            "connect 1.2.3.4:5555",
            "connect 1.2.3.4:5555",
            "devices -l",
        ])
    }

    @Test func operationDeadlineBoundsHungCommandAndInheritedOutput() throws {
        let fixture = try FakeADB(responses: [], scripts: [("devices -l", "sleep 2 & wait")])
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try fixture.bridge.withOperation(ADBOperation(timeout: 1)).devices()
            Issue.record("Expected operationTimedOut")
        } catch ADBError.operationTimedOut {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.8)
        #expect(try fixture.commands() == ["devices -l"])
    }

    @Test func commandExitDoesNotWaitForInheritedOutputDescriptor() throws {
        let fixture = try FakeADB(responses: [], scripts: [("devices -l", "sleep 2 & echo 'USB device'; exit 0")])
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(try fixture.bridge.devices() == [AdbDevice(serial: "USB", state: "device")])
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
    }

    @Test func cancellationStopsOwnedCommandWithoutKillingDaemon() async throws {
        let fixture = try FakeADB(responses: [], scripts: [("devices -l", "exec sleep 30")])
        defer { fixture.remove() }
        let operation = ADBOperation()
        let bridge = fixture.bridge.withOperation(operation)
        let task = Task.detached { try bridge.devices() }
        while try fixture.commands().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.commands() == ["devices -l"])
    }

    @Test func taskCancellationStopsOwnedCommand() async throws {
        let fixture = try FakeADB(responses: [], scripts: [("devices -l", "exec sleep 30")])
        defer { fixture.remove() }
        let bridge = fixture.bridge
        let task = Task.detached { try bridge.devices() }
        while try fixture.commands().isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func unboundCommandHasTenSecondLimit() throws {
        let fixture = try FakeADB(responses: [], scripts: [("devices -l", "exec sleep 30")])
        defer { fixture.remove() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try fixture.bridge.devices()
            Issue.record("Expected commandTimedOut")
        } catch ADBError.commandTimedOut {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(ProcessInfo.processInfo.systemUptime - started < 12)
        #expect(try fixture.commands() == ["devices -l"])
    }

    @Test func operationCancellationAndDeadline() {
        let cancelled = ADBOperation()
        cancelled.cancel()
        #expect(throws: CancellationError.self) { try cancelled.checkCancellation() }
        let expired = ADBOperation(timeout: 0)
        #expect(expired.remaining == 0)
        #expect(throws: ADBError.self) { try expired.checkCancellation() }
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

private struct FakeADB {
    let directory: URL
    let bridge: ADBBridge

    init(responses: [(String, String, Int32)], scripts: [(String, String)] = []) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskbridge-adb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("commands")
        let cases = (scripts.map { arguments, body in
            "\(Self.quote(arguments))) \(body);;"
        } + responses.map { arguments, output, status in
            "\(Self.quote(arguments))) printf '%s\\n' \(Self.quote(output)); exit \(status);;"
        }).joined(separator: "\n")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(Self.quote(log.path))
        case "$*" in
        \(cases)
        *) echo 'Unexpected fake adb command' >&2; exit 99;;
        esac
        """
        do {
            try Data().write(to: log)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            bridge = try ADBBridge(adbPath: executable.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func commands() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
