import AppKit
import DeskBridgeCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase {
        case paused, searching, connected, controlling
    }

    var phase = Phase.searching
    var status = "Looking for a device…"
    var needsAccessibility = false

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

    init() {
        prefs = settings.values
        launchAtLogin = LoginItem.isEnabled
        if !prefs.enabled {
            phase = .paused
            status = "Paused"
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
            status = "Looking for a device…"
            retryNotBefore = .distantPast
        } else {
            phase = .paused
            status = "Paused"
            session?.stop() // the .ended callback clears `session`
        }
    }

    private func loginItemChanged() {
        guard !syncingLoginItem else { return }
        do {
            try LoginItem.set(launchAtLogin)
        } catch {
            status = "Launch at login failed: \(error.localizedDescription)"
            syncingLoginItem = true
            launchAtLogin = LoginItem.isEnabled
            syncingLoginItem = false
        }
    }

    // MARK: - Discovery

    private func discoveryLoop() async {
        while !Task.isCancelled {
            if isEnabled, session == nil, Date() >= retryNotBefore {
                await tryStartSession()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func tryStartSession() async {
        guard Permissions.accessibilityGranted else {
            status = "Allow DeskBridge in Accessibility. If it is already listed, remove it with \u{2212} and add it again."
            needsAccessibility = true
            return
        }
        needsAccessibility = false
        guard let jar = ServerJar.locate() else {
            status = "deskbridge-server.jar not found. Run scripts/build_server.sh"
            return
        }
        do {
            let adb = try ADBBridge()
            let devices = try await Task.detached { try adb.devices() }.value
            switch DevicePicker.pick(from: devices) {
            case .none:
                status = "Connect an Android device with USB debugging"
            case let .notReady(device):
                status = "Authorize this Mac on the device (\(device.state))"
            case let .ready(device):
                let name = await Task.detached { adb.deviceName(serial: device.serial) }.value
                guard isEnabled, session == nil else { return }
                startSession(adb: adb, serial: device.serial, name: name, jar: jar)
            }
        } catch {
            status = "\(error)"
        }
    }

    private func startSession(adb: ADBBridge, serial: String, name: String, jar: URL) {
        status = "Connecting to \(name)…"
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
            status = "Connecting to \(name)…"
        case .local:
            reachedConnected = true
            backoff.reset()
            phase = .connected
            status = "Connected to \(name)"
        case .remote:
            phase = .controlling
            status = "Controlling \(name). ⌃⌥⌘⎋ to release."
        case let .ended(reason):
            session = nil // the discovery loop starts a new session
            phase = isEnabled ? .searching : .paused
            status = isEnabled ? reason.description : "Paused"
            if reason == .captureDenied {
                needsAccessibility = true
            }
            if !reachedConnected {
                backoff.recordFailure() // never got going: wait longer each time
                retryNotBefore = Date().addingTimeInterval(backoff.delay)
            }
        }
    }
}
