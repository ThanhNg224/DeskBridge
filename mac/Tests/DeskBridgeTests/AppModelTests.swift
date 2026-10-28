@testable import DeskBridge
import DeskBridgeCore
import Foundation
import Testing

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value.addTimeInterval(seconds) }
    }
}

/// Deliberately ignores cancellation so tests can deliver obsolete I/O completions.
private actor ResultGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var result: String?
    private(set) var waiting = false
    func wait() async -> String {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting = true
        }
    }

    func resolve(_ value: String = "") {
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private final class FakeSession: AppSession, @unchecked Sendable {
    var onStateChange: (@Sendable (DeviceSession.State) -> Void)?
    let serial: String
    var starts = 0
    var stops = 0
    init(_ serial: String) {
        self.serial = serial
    }

    func start() {
        starts += 1
    }

    func stop() {
        stops += 1
    }

    func stopAndWait() {
        stop()
    }

    func settingsChanged() {}
    func emit(_ state: DeviceSession.State) {
        onStateChange?(state)
    }
}

@MainActor
private final class ModelFixture {
    let suite = "DeskBridge.AppModelTests.\(UUID().uuidString)"
    let clock = TestClock()
    var devices: [AdbDevice] = []
    var sessions: [FakeSession] = []
    var requests: [WirelessRequest] = []
    var discovery: (() async -> [AdbDevice])?
    var wireless: (WirelessRequest) async throws -> String = { request in
        switch request {
        case let .connect(ip, port): "\(ip):\(port)"
        case let .disconnect(serial): serial
        case .switchFromUSB: "192.168.1.7:5555"
        }
    }

    var model: AppModel!

    init(selected: String? = nil, devices: [AdbDevice] = [], deadline: ResultGate? = nil,
         install: (@Sendable (URL) async throws -> Void)? = nil,
         update: (@Sendable (String) async throws -> URL?)? = nil)
    {
        self.devices = devices
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)
        var values = settings.values
        values.preferredSerial = selected
        settings.values = values
        var dependencies = AppDependencies()
        if let install {
            dependencies.installADB = install
        }
        if let update {
            dependencies.checkRelease = update
        }
        dependencies.installedVersion = { "1.1.7" }
        dependencies.adb = { try ADBBridge(adbPath: "/usr/bin/true") }
        dependencies.devices = { [weak self] _ in await self?.discoveredDevices() ?? [] }
        dependencies.wireless = { [weak self] _, request, _ in
            guard let self else { throw CancellationError() }
            return try await perform(request)
        }
        dependencies.session = { [weak self] _, phone, _, _, _ in
            let session = FakeSession(phone.serial)
            self?.sessions.append(session)
            return session
        }
        dependencies.accessibility = { true }
        dependencies.jar = { URL(fileURLWithPath: "/test/deskbridge-server.jar") }
        let clock = clock
        dependencies.now = { clock.now() }
        dependencies.sleep = { _ in
            if let deadline {
                _ = await deadline.wait()
            } else {
                try await Task.sleep(for: .seconds(3600))
            }
        }
        model = AppModel(settings: settings, dependencies: dependencies,
                         integratesWithSystem: false, pollsAutomatically: false)
    }

    private func discoveredDevices() async -> [AdbDevice] {
        if let discovery {
            return await discovery()
        }
        return devices
    }

    private func perform(_ request: WirelessRequest) async throws -> String {
        requests.append(request)
        return try await wireless(request)
    }

    func close() {
        model.shutdown()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@MainActor
struct AppModelTests {
    private let usb = AdbDevice(serial: "USB-A", state: "device")
    private let other = AdbDevice(serial: "USB-B", state: "device")
    private let wifi = AdbDevice(serial: "192.168.1.7:5555", state: "device")

    private func eventually(_ condition: @MainActor () -> Bool,
                            sourceLocation: SourceLocation = #_sourceLocation) async
    {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), "Condition did not become true", sourceLocation: sourceLocation)
    }

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    @Test func pinnedUSBWaitsForItsReturnInsteadOfUsingUnrelatedWiFi() async {
        let f = ModelFixture(selected: usb.serial, devices: [usb, wifi])
        defer { f.close() }
        await f.model.refreshNow()
        let first = f.sessions[0]
        first.emit(.local)
        await eventually { f.model.activePhone?.serial == usb.serial }
        f.devices = [wifi]
        await f.model.refreshNow()
        #expect(first.stops == 1)
        first.emit(.ended(.stopped))
        await settle()
        await f.model.refreshNow()
        #expect(f.model.prefs.preferredSerial == usb.serial)
        #expect(f.model.selectedPhone?.state == "offline")
        #expect(f.sessions.map(\.serial) == [usb.serial])
        f.devices = [wifi, usb]
        await f.model.refreshNow()
        #expect(f.sessions.map(\.serial) == [usb.serial, usb.serial])
    }

    @Test func selectedDeviceKeepsItsNameWhenADBReportsOfflineWithoutModel() async {
        let namedUSB = AdbDevice(serial: usb.serial, state: "device", model: "OPPO")
        let f = ModelFixture(selected: usb.serial, devices: [namedUSB, wifi])
        defer { f.close() }
        await f.model.refreshNow()
        f.devices = [AdbDevice(serial: usb.serial, state: "offline"), wifi]
        await f.model.refreshNow()
        f.sessions[0].emit(.ended(.stopped))
        await settle()
        await f.model.refreshNow()
        #expect(f.model.selectedPhone?.displayName == "OPPO")
        #expect(f.model.status.contains("OPPO"))
    }

    @Test func oneReadyDevicePinsItselfAndMultipleReadyDevicesWaitForSelection() async {
        let single = ModelFixture(devices: [usb])
        defer { single.close() }
        await single.model.refreshNow()
        #expect(single.model.prefs.preferredSerial == usb.serial)
        #expect(single.sessions.count == 1)
        let multiple = ModelFixture(devices: [usb, wifi])
        defer { multiple.close() }
        await multiple.model.refreshNow()
        #expect(multiple.model.prefs.preferredSerial == nil)
        #expect(multiple.sessions.isEmpty)
        multiple.model.selectDevice(serial: wifi.serial)
        await eventually { multiple.sessions.count == 1 }
        #expect(multiple.sessions.first?.serial == wifi.serial)
    }

    @Test func staleDiscoveryCompletionCannotReplaceNewSelectionOrDeviceList() async {
        let gate = ResultGate()
        let f = ModelFixture(selected: usb.serial)
        defer { f.close() }
        let oldDevices = [usb]
        let newDevices = [usb, wifi]
        var discoveries = 0
        f.discovery = {
            discoveries += 1
            if discoveries == 1 {
                _ = await gate.wait()
                return oldDevices
            }
            return newDevices
        }
        let oldRefresh = Task { await f.model.refreshNow() }
        await eventually { discoveries == 1 }
        f.model.selectDevice(serial: wifi.serial)
        await eventually { f.sessions.count == 1 }
        let current = f.sessions[0]
        #expect(current.serial == wifi.serial)
        current.emit(.local)
        await eventually { f.model.activePhone?.serial == wifi.serial }
        await gate.resolve()
        await oldRefresh.value
        #expect(f.model.prefs.preferredSerial == wifi.serial)
        #expect(f.model.activePhone?.serial == wifi.serial)
        #expect(f.model.phase == .connected)
        #expect(f.model.setup.phones.map(\.serial) == [usb.serial, wifi.serial])
        #expect(f.sessions.count == 1)
        #expect(current.stops == 0)
    }

    @Test func rapidSelectionWaitsForTeardownAndIgnoresOldCallbacks() async {
        let f = ModelFixture(selected: usb.serial, devices: [usb, other])
        defer { f.close() }
        await f.model.refreshNow()
        let old = f.sessions[0]
        f.model.selectDevice(serial: other.serial)
        f.model.selectDevice(serial: usb.serial)
        await f.model.refreshNow()
        #expect(f.sessions.count == 1)
        old.emit(.local)
        await settle()
        #expect(f.model.activePhone == nil)
        old.emit(.ended(.stopped))
        await eventually { f.sessions.count == 2 }
        let current = f.sessions[1]
        #expect(current.serial == usb.serial)
        current.emit(.local)
        await eventually { f.model.activePhone?.serial == usb.serial }
        old.emit(.ended(.deviceSilent))
        old.emit(.local)
        await settle()
        #expect(f.model.activePhone?.serial == usb.serial)
        #expect(f.model.phase == .connected)
        #expect(current.stops == 0)
    }

    @Test func nilPickerPlaceholderCannotClearPinnedSelection() async {
        let f = ModelFixture(selected: usb.serial, devices: [usb])
        defer { f.close() }
        await f.model.refreshNow()
        f.model.selectDevice(serial: nil)
        #expect(f.model.prefs.preferredSerial == usb.serial)
        #expect(f.sessions[0].stops == 0)
    }

    @Test func wirelessInputClearsOnlyAfterExactCandidateHandshake() async {
        let f = ModelFixture(selected: usb.serial, devices: [usb, wifi])
        defer { f.close() }
        f.model.wirelessIP = "192.168.1.7"
        f.model.wirelessPort = "5555"
        f.model.connectWireless()
        await eventually { f.sessions.count == 1 }
        #expect(f.sessions[0].serial == wifi.serial)
        #expect(f.model.activePhone == nil)
        #expect(f.model.pendingPhone?.serial == wifi.serial)
        #expect(f.model.isOperatingWireless)
        #expect(f.model.wirelessIP == "192.168.1.7")
        f.sessions[0].emit(.starting)
        await settle()
        #expect(f.model.wirelessIP == "192.168.1.7")
        f.sessions[0].emit(.local)
        await eventually { !f.model.isOperatingWireless }
        #expect(f.model.activePhone?.serial == wifi.serial)
        #expect(f.model.wirelessIP.isEmpty)
        #expect(f.model.wirelessPort == "5555")
    }

    @Test(arguments: ["cancel", "select", "disable"])
    func lateWirelessPreparationCannotOverrideNewIntent(_ action: String) async {
        let gate = ResultGate()
        let f = ModelFixture(selected: usb.serial, devices: [usb, other, wifi])
        defer { f.close() }
        f.wireless = { _ in await gate.wait() }
        f.model.wirelessIP = "192.168.1.7"
        f.model.connectWireless()
        await eventually { f.requests.count == 1 }
        switch action {
        case "cancel": f.model.cancelWireless()
        case "select": f.model.selectDevice(serial: other.serial)
        default: f.model.isEnabled = false
        }
        await gate.resolve(wifi.serial)
        await settle()
        await f.model.refreshNow()
        #expect(!f.model.isOperatingWireless)
        #expect(f.model.prefs.preferredSerial == (action == "select" ? other.serial : usb.serial))
        #expect(!f.sessions.contains { $0.serial == wifi.serial })
        #expect(f.model.wirelessIP == "192.168.1.7")
        if action == "disable" {
            #expect(f.model.phase == .paused)
        }
    }

    @Test func explicitDisconnectSuppressesBrieflyReadyEndpoint() async {
        let f = ModelFixture(selected: wifi.serial, devices: [wifi])
        defer { f.close() }
        await f.model.refreshNow()
        let session = f.sessions[0]
        session.emit(.local)
        await eventually { f.model.activePhone != nil }
        f.model.disconnectWireless(serial: wifi.serial)
        session.emit(.ended(.stopped))
        await eventually { !f.model.isOperatingWireless }
        await f.model.refreshNow()
        await f.model.refreshNow()
        #expect(f.requests == [.disconnect(wifi.serial)])
        #expect(f.sessions.count == 1)
        #expect(f.model.activePhone == nil)
        #expect(f.model.prefs.preferredSerial == wifi.serial)
    }

    @Test func reconnectUsesSelectedEndpointAndBackoffWithManualRetryAndSuccessReset() async {
        let f = ModelFixture(selected: "192.168.1.7:7777", devices: [usb, wifi])
        defer { f.close() }
        f.wireless = { _ in throw ADBError.operationTimedOut }
        let expected = WirelessRequest.connect("192.168.1.7", 7777)
        await f.model.refreshNow()
        #expect(f.requests == [expected])
        await f.model.refreshNow()
        #expect(f.requests.count == 1)
        f.clock.advance(2)
        await f.model.refreshNow()
        #expect(f.requests == [expected, expected])
        f.clock.advance(2)
        await f.model.refreshNow()
        #expect(f.requests.count == 2)
        f.model.retryConnection()
        await eventually { f.requests.count == 3 }
        f.devices.append(AdbDevice(serial: "192.168.1.7:7777", state: "device"))
        f.clock.advance(2)
        await f.model.refreshNow()
        #expect(f.sessions.count == 1)
        f.sessions[0].emit(.local)
        await eventually { f.model.activePhone != nil }
        f.sessions[0].emit(.ended(.deviceSilent))
        await eventually { f.model.activePhone == nil }
        await settle()
        f.clock.advance(2)
        await f.model.refreshNow()
        #expect(f.sessions.count == 2)
        #expect(f.requests.allSatisfy { $0 == expected })
    }

    @Test(arguments: [false, true])
    func wirelessDeadlineOrSessionFailureRestoresOriginAndKeepsInputs(_ timeout: Bool) async {
        let deadline = ResultGate()
        let f = ModelFixture(selected: usb.serial, devices: [usb, wifi], deadline: deadline)
        defer { f.close() }
        f.model.wirelessIP = "192.168.1.7"
        f.model.connectWireless()
        await eventually { f.sessions.count == 1 }
        let candidate = f.sessions[0]
        if timeout {
            await deadline.resolve()
        } else {
            candidate.emit(.ended(.adbFailed("test failure")))
            await eventually { f.model.wirelessErrorMessage != nil }
            await deadline.resolve()
        }
        await eventually { f.model.wirelessErrorMessage != nil }
        #expect(f.model.prefs.preferredSerial == usb.serial)
        #expect(f.model.wirelessIP == "192.168.1.7")
        #expect(!f.model.isOperatingWireless)
        #expect(f.model.activePhone == nil)
        if timeout {
            #expect(candidate.stops > 0)
        }
        candidate.emit(.local)
        await settle()
        #expect(f.model.activePhone == nil)
    }

    @Test func manualUpdateCheckReportsNewVersionWithoutOpeningIt() async throws {
        let expected = try #require(URL(string: "https://github.com/ThanhNg224/DeskBridge/releases/tag/v1.2.0"))
        let f = ModelFixture(update: { _ in expected })
        defer { f.close() }
        f.model.checkForUpdates()
        await eventually { !f.model.checkingUpdates }
        #expect(f.model.updateURL == expected)
        #expect(f.model.updateMessage != nil)
    }

    @Test func successfulADBInstallRestartsDiscoveryAndKeepsSelection() async {
        let f = ModelFixture(selected: usb.serial, devices: [usb], install: { _ in })
        defer { f.close() }
        f.model.setup.adbFound = false
        f.model.installADB(from: URL(fileURLWithPath: "/tmp/tools.zip"))
        await eventually { !f.model.installingADB && f.model.setup.adbFound }
        #expect(f.model.prefs.preferredSerial == usb.serial)
        #expect(f.model.adbInstallError == nil)
    }

    @Test func failedADBInstallShowsErrorAndPreservesSelection() async {
        let f = ModelFixture(selected: usb.serial, install: { _ in throw ManagedADB.InstallError.invalidArchive })
        defer { f.close() }
        f.model.installADB(from: URL(fileURLWithPath: "/tmp/bad.zip"))
        await eventually { !f.model.installingADB }
        #expect(f.model.adbInstallError != nil)
        #expect(f.model.prefs.preferredSerial == usb.serial)
    }
}
