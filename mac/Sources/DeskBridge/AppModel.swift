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

    private func discoveryLoop() async {
        var tick = 0
        while !Task.isCancelled {
            refreshSetup()
            if isEnabled, session == nil, Date() >= retryNotBefore {
                await tryStartSession()
            } else if session != nil, tick % 5 == 0 {
                await refreshPhones() // so a second phone plugged in meanwhile shows up in the picker
            }
            tick += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func refreshPhones() async {
        guard let adb = try? ADBBridge(), let devices = try? await Task.detached(operation: { try adb.devices() }).value
        else { return }
        setup.phones = devices.filter(\.isReady)
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
            let pick = DevicePicker.pick(from: devices, preferredSerial: prefs.preferredSerial)
            setup.phones = devices.filter(\.isReady)
            switch pick {
            case let .choose(candidates):
                setup.device = .choose(candidates.count)
                status = StatusText.choosePhone(count: candidates.count)
            case .none:
                setup.device = .none
                status = StatusText.noDevice
            case let .notReady(device):
                setup.device = .notAuthorized(device.state)
                status = StatusText.notAuthorized(device.state)
            case let .ready(device):
                let name = device.displayName
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
        }
    }
}
