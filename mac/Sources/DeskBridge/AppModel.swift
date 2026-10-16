import AppKit
import DeskBridgeCore
import Observation
import os

@MainActor @Observable
final class AppModel {
    enum Phase {
        case paused, searching, connected, controlling
    }

    enum WirelessOperation {
        case idle, connecting, switching, disconnecting
    }

    var phase = Phase.searching
    var status = StatusText.searching
    var setup = SetupState()

    var wirelessIP = ""
    var wirelessPort = "5555"
    private(set) var wirelessOperation = WirelessOperation.idle
    var wirelessErrorMessage: String?

    var isOperatingWireless: Bool {
        wirelessOperation != .idle
    }

    var selectedPhone: AdbDevice? {
        if case let .ready(phone) = DevicePicker.pick(from: setup.phones, preferredSerial: prefs.preferredSerial) {
            return phone
        }
        return nil
    }

    var canConnectWireless: Bool {
        !isOperatingWireless && (try? wirelessInput()) != nil
    }

    var wirelessInputError: String? {
        guard !wirelessIP.isEmpty || wirelessPort != "5555" else { return nil }
        do {
            _ = try wirelessInput()
            return nil
        } catch {
            return wirelessMessage(for: error)
        }
    }

    var prefs: Settings.Values {
        didSet {
            settings.values = prefs
            session?.settingsChanged()
            if let current = sessionSerial, let wanted = prefs.preferredSerial,
               oldValue.preferredSerial != wanted, wanted != current
            {
                session?.stop() // the discovery loop reconnects to the phone that was just chosen
            }
        }
    }

    /// Master switch: off stops the session and keeps the app idle.
    var isEnabled: Bool {
        get { prefs.enabled }
        set {
            prefs.enabled = newValue
            enabledChanged()
        }
    }

    var showDockIcon: Bool {
        get { prefs.showDockIcon }
        set {
            prefs.showDockIcon = newValue
            applyDockIcon()
        }
    }

    var launchAtLogin: Bool {
        didSet { loginItemChanged() }
    }

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var reachedConnected = false
    @ObservationIgnored private var sessionSerial: String?
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var syncingLoginItem = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DeviceWatcher?

    init() {
        prefs = settings.values
        launchAtLogin = LoginItem.isEnabled
        if !prefs.enabled {
            phase = .paused
            status = StatusText.paused
        }
        applyDockIcon()
        Permissions.requestAccessibility() // once; the loop below only checks silently
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watcher?.stop()
                self?.session?.stopAndWait()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Back from System Settings, say: re-check now. Not during a session (the cursor shield activates the app).
            MainActor.assumeIsolated {
                if let model = self, model.session == nil {
                    model.wakeDiscovery()
                }
            }
        }
        wakeDiscovery()
    }

    // MARK: - Switches

    private func enabledChanged() {
        if isEnabled {
            phase = .searching
            status = StatusText.searching
            retryNotBefore = .distantPast
            wakeDiscovery()
        } else {
            phase = .paused
            status = StatusText.paused
            session?.stop() // the .ended callback clears `session`
        }
    }

    private func applyDockIcon() {
        NSApplication.shared.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
    }

    private func loginItemChanged() {
        guard !syncingLoginItem else { return }
        do {
            try LoginItem.set(launchAtLogin)
        } catch {
            status = error.localizedDescription
            syncingLoginItem = true
            launchAtLogin = LoginItem.isEnabled
            syncingLoginItem = false
        }
    }

    // MARK: - Discovery

    /// Runs one discovery pass now and restarts the polling clock (the loop sleeps long when nothing changes).
    private func wakeDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task { await discoveryLoop() }
    }

    private func discoveryLoop() async {
        while !Task.isCancelled {
            startWatcherIfNeeded()
            if session != nil {
                await refreshPhones() // so a second phone plugged in meanwhile shows up in the picker
            } else {
                refreshSetup()
                if !isEnabled {
                    await refreshPhones()
                } else if Date() >= retryNotBefore {
                    await tryStartSession()
                }
            }
            try? await Task.sleep(for: .seconds(pollSeconds))
        }
    }

    /// `adb track-devices` tells when a phone is plugged in or out, so no polling is needed for that.
    private func startWatcherIfNeeded() {
        guard watcher == nil, let path = ADBBridge.locate() else { return }
        let watcher = DeviceWatcher(adbPath: path)
        self.watcher = watcher
        watcher.start { [weak self] in
            Task { @MainActor in self?.wakeDiscovery() }
        }
    }

    /// While the watcher runs the loop is only a safety net (and the retry clock after a failed start); without it
    /// (adb missing, or not started yet) each pass spawns `adb`, so poll gently.
    private var pollSeconds: Double {
        var seconds: Double = if watcher?.isAlive == true {
            session != nil ? 60 : 30
        } else if session != nil {
            10
        } else if !isEnabled {
            5
        } else if case .none = setup.device {
            4 // no phone plugged in
        } else {
            2
        }
        if session == nil, isEnabled, retryNotBefore > Date() {
            seconds = min(seconds, max(1, retryNotBefore.timeIntervalSinceNow)) // the back-off ends sooner
        }
        return seconds
    }

    private func refreshPhones() async {
        guard let adb = try? ADBBridge(), let devices = try? await Task.detached(operation: { try adb.devices() }).value
        else { return }
        _ = updateDevices(devices)
    }

    @discardableResult
    private func updateDevices(_ devices: [AdbDevice]) -> DevicePick {
        setup.phones = devices.filter(\.isReady)
        let pick = DevicePicker.pick(from: devices, preferredSerial: prefs.preferredSerial)
        switch pick {
        case let .ready(device): setup.device = .ready(device.displayName)
        case let .choose(devices): setup.device = .choose(devices.count)
        case let .notReady(device): setup.device = .notAuthorized(device.state)
        case .none: setup.device = .none
        }
        return pick
    }

    private func refreshSetup() {
        setup.accessibility = Permissions.accessibilityGranted
        setup.adbFound = ADBBridge.locate() != nil
    }

    private func tryStartSession() async {
        guard setup.accessibility else {
            status = StatusText.needsAccessibility
            return
        }
        guard let jar = ServerJar.locate() else {
            status = StatusText.jarMissing
            return
        }
        guard setup.adbFound, let adb = try? ADBBridge() else {
            status = StatusText.noDevice
            return
        }
        do {
            let devices = try await Task.detached { try adb.devices() }.value
            let pick = updateDevices(devices)
            switch pick {
            case let .choose(candidates):
                status = StatusText.choosePhone(count: candidates.count)
            case .none:
                status = StatusText.noDevice
            case let .notReady(device):
                status = StatusText.notAuthorized(device.state)
            case let .ready(device):
                let name = device.displayName
                guard isEnabled, session == nil else { return }
                startSession(adb: adb, serial: device.serial, name: name, jar: jar)
            }
        } catch {
            status = "\(error)"
        }
    }

    private func startSession(adb: ADBBridge, serial: String, name: String, jar: URL) {
        status = StatusText.connecting(name)
        reachedConnected = false
        sessionSerial = serial
        let session = DeviceSession(adb: adb, serial: serial, jar: jar, settings: settings)
        session.onStateChange = { [weak self, weak session] state in
            Task { @MainActor in
                guard let model = self, let session else { return }
                model.apply(state, name: name, from: session)
            }
        }
        self.session = session
        session.start()
    }

    private func apply(_ state: DeviceSession.State, name: String, from source: DeviceSession) {
        guard session === source else { return } // ignore callbacks of an older session
        switch state {
        case .starting:
            phase = .searching
            status = StatusText.connecting(name)
        case .local:
            reachedConnected = true
            backoff.reset()
            phase = .connected
            status = StatusText.connected(name)
        case .remote:
            phase = .controlling
            status = StatusText.controlling(name)
        case .ended(.stopped):
            // We stopped it (switch off, or another phone chosen): not a failure, no back-off.
            session = nil
            sessionSerial = nil
            phase = isEnabled ? .searching : .paused
            status = isEnabled ? StatusText.searching : StatusText.paused
            wakeDiscovery()
        case let .ended(reason):
            session = nil // the discovery loop starts a new session
            sessionSerial = nil
            phase = isEnabled ? .searching : .paused
            status = isEnabled ? StatusText.ended(reason) : StatusText.paused
            if reason == .captureDenied {
                setup.accessibility = false
            }
            if !reachedConnected {
                backoff.recordFailure() // never got going: wait longer each time
                retryNotBefore = Date().addingTimeInterval(backoff.delay)
            }
            wakeDiscovery()
        }
    }

    // MARK: - Wireless ADB

    func switchToWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial, selectedPhone?.isWireless == false else { return }
        guard let adb = try? ADBBridge() else {
            wirelessErrorMessage = wirelessMessage(for: ADBError.adbNotFound)
            return
        }
        wirelessOperation = .switching
        wirelessErrorMessage = nil
        Task {
            defer { wirelessOperation = .idle }
            do {
                let target = try await Task.detached {
                    try await adb.switchToWireless(serial: serial)
                }.value
                prefs.preferredSerial = target
                wakeDiscovery()
            } catch {
                wirelessErrorMessage = wirelessMessage(for: error)
            }
        }
    }

    func connectWireless() {
        guard !isOperatingWireless else { return }
        let input: (ip: String, port: Int)
        do {
            input = try wirelessInput()
        } catch {
            wirelessErrorMessage = wirelessMessage(for: error)
            return
        }
        guard let adb = try? ADBBridge() else {
            wirelessErrorMessage = wirelessMessage(for: ADBError.adbNotFound)
            return
        }
        wirelessOperation = .connecting
        wirelessErrorMessage = nil
        Task {
            defer { wirelessOperation = .idle }
            do {
                let target = try await Task.detached {
                    try await adb.connectWireless(ip: input.ip, port: input.port)
                }.value
                prefs.preferredSerial = target
                wirelessIP = ""
                wirelessPort = "5555"
                wakeDiscovery()
            } catch {
                wirelessErrorMessage = wirelessMessage(for: error)
            }
        }
    }

    func disconnectWireless(serial: String) {
        guard !isOperatingWireless, selectedPhone?.serial == serial, selectedPhone?.isWireless == true else { return }
        guard let adb = try? ADBBridge() else {
            wirelessErrorMessage = wirelessMessage(for: ADBError.adbNotFound)
            return
        }
        wirelessOperation = .disconnecting
        wirelessErrorMessage = nil
        Task {
            defer { wirelessOperation = .idle }
            do {
                _ = try await Task.detached {
                    try adb.disconnectWireless(serial: serial)
                }.value
                if prefs.preferredSerial == serial {
                    prefs.preferredSerial = nil
                }
                wakeDiscovery()
            } catch {
                wirelessErrorMessage = wirelessMessage(for: error)
            }
        }
    }

    private func wirelessInput() throws -> (ip: String, port: Int) {
        guard let port = Int(wirelessPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ADBError.invalidWirelessPort
        }
        _ = try ADBBridge.wirelessTarget(ip: wirelessIP, port: port)
        return (wirelessIP, port)
    }

    private func wirelessMessage(for error: Error) -> String {
        switch error as? ADBError {
        case .invalidWirelessIP:
            return String(localized: "Enter a valid IPv4 address, such as 192.168.1.75.")
        case .invalidWirelessPort:
            return String(localized: "Enter a port between 1 and 65535.")
        case .noWifiIPFound:
            return String(localized: "No Wi-Fi address found. Connect the phone to Wi-Fi, then try again.")
        case .adbNotFound:
            return String(localized: "Android tools (adb) are missing. Install them to connect.")
        default:
            Logger(subsystem: "com.deskbridge.app", category: "Wireless")
                .error("Wireless ADB failed: \(String(describing: error))")
            return String(localized: "The Wi-Fi action failed. Check the phone and your network, then try again.")
        }
    }
}
