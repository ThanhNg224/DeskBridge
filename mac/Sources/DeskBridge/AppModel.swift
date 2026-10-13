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
                if isEnabled, Date() >= retryNotBefore {
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
}
