import AppKit
import DeskBridgeCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase {
        case paused, searching, connected, controlling
    }

    var phase = Phase.searching
    var status = StatusText.searching
    var setup = SetupState()

    var prefs: Settings.Values {
        didSet { settings.values = prefs }
    }

    /// Master switch: off stops the session and keeps the app idle.
    var isEnabled: Bool {
        get { prefs.enabled }
        set {
            prefs.enabled = newValue
            enabledChanged()
        }
    }

    var launchAtLogin: Bool {
        didSet { loginItemChanged() }
    }

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var reachedConnected = false
    @ObservationIgnored private var backoff = Backoff()
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var syncingLoginItem = false
    @ObservationIgnored private var openedSettingsForSetup = false

    init() {
        prefs = settings.values
        launchAtLogin = LoginItem.isEnabled
        if !prefs.enabled {
            phase = .paused
            status = StatusText.paused
        }
        Permissions.requestAccessibility() // once; the loop below only checks silently
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.stopAndWait() }
        }
        Task { await discoveryLoop() }
    }

    // MARK: - Switches

    private func enabledChanged() {
        if isEnabled {
            phase = .searching
            status = StatusText.searching
            retryNotBefore = .distantPast
        } else {
            phase = .paused
            status = StatusText.paused
            session?.stop() // the .ended callback clears `session`
        }
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

    private func discoveryLoop() async {
        while !Task.isCancelled {
            refreshSetup()
            if isEnabled, session == nil, Date() >= retryNotBefore {
                await tryStartSession()
            }
            openSettingsOnceIfSetupIncomplete()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshSetup() {
        setup.accessibility = Permissions.accessibilityGranted
        setup.adbFound = ADBBridge.locate() != nil
    }

    /// First run (or after losing a permission): show the checklist once instead of a silent menu bar icon.
    private func openSettingsOnceIfSetupIncomplete() {
        guard !openedSettingsForSetup, !setup.isComplete, !setup.accessibility || !setup.adbFound else { return }
        openedSettingsForSetup = true
        SettingsWindow.open()
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
            switch DevicePicker.pick(from: devices) {
            case .none:
                setup.device = .none
                status = StatusText.noDevice
            case let .notReady(device):
                setup.device = .notAuthorized(device.state)
                status = StatusText.notAuthorized(device.state)
            case let .ready(device):
                let name = await Task.detached { adb.deviceName(serial: device.serial) }.value
                setup.device = .ready(name)
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
        case let .ended(reason):
            session = nil // the discovery loop starts a new session
            phase = isEnabled ? .searching : .paused
            status = isEnabled ? StatusText.ended(reason) : StatusText.paused
            if reason == .captureDenied {
                setup.accessibility = false
            }
            if !reachedConnected {
                backoff.recordFailure() // never got going: wait longer each time
                retryNotBefore = Date().addingTimeInterval(backoff.delay)
            }
        }
    }
}
