import AppKit
import ApplicationServices
import DeskBridgeCore
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    enum Phase {
        case paused, searching, connected, controlling
    }

    var phase = Phase.searching
    var status = "Looking for a device…"
    var needsAccessibility = false

    /// Master switch: off stops the session and keeps the app idle.
    var isEnabled: Bool {
        didSet { enabledChanged() }
    }

    var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    var prefs: Settings.Values {
        didSet { settings.values = prefs }
    }

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var retryNotBefore = Date.distantPast
    @ObservationIgnored private var syncingLoginItem = false

    init() {
        prefs = settings.values
        isEnabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if !isEnabled {
            phase = .paused
            status = "Paused"
        }
        // Ask for the permission exactly once; the loop below only checks it silently.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.stopAndWait() }
        }
        Task { await discoveryLoop() }
    }

    // MARK: - Switches

    private func enabledChanged() {
        UserDefaults.standard.set(isEnabled, forKey: "enabled")
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

    private func updateLoginItem() {
        guard !syncingLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = "Launch at login failed: \(error.localizedDescription)"
            syncingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
        guard AXIsProcessTrusted() else {
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
            guard let device = devices.first(where: \.isReady) else {
                status = devices.isEmpty
                    ? "Connect an Android device with USB debugging"
                    : "Authorize this Mac on the device (\(devices[0].state))"
                return
            }
            let name = await Task.detached { adb.deviceName(serial: device.serial) }.value
            guard isEnabled, session == nil else { return }

            status = "Connecting to \(name)…"
            let session = DeviceSession(adb: adb, serial: device.serial, jar: jar, settings: settings)
            session.onStateChange = { [weak self, weak session] state in
                Task { @MainActor in
                    guard let self, let session else { return }
                    self.apply(state, name: name, from: session)
                }
            }
            self.session = session
            session.start()
        } catch {
            status = "\(error)"
        }
    }

    private func apply(_ state: DeviceSession.State, name: String, from source: DeviceSession) {
        guard session === source else { return } // ignore callbacks of an older session
        switch state {
        case .starting:
            phase = .searching
            status = "Connecting to \(name)…"
        case .local:
            phase = .connected
            status = "Connected to \(name)"
        case .remote:
            phase = .controlling
            status = "Controlling \(name). ⌃⌥⌘⎋ to release."
        case let .ended(reason):
            session = nil // the discovery loop starts a new session
            if isEnabled {
                phase = .searching
                status = reason
            } else {
                phase = .paused
                status = "Paused"
            }
            if reason == CaptureError.tapCreationFailed.description {
                needsAccessibility = true
                retryNotBefore = Date().addingTimeInterval(20) // do not relaunch the server in a tight loop
            }
        }
    }
}
