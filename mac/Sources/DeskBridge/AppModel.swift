import AppKit
import ApplicationServices
import DeskBridgeCore
import Observation

@MainActor @Observable
final class AppModel {
    var status = "Looking for a device…"
    var isActive = false
    var needsAccessibility = false
    var prefs: Settings.Values {
        didSet { settings.values = prefs }
    }

    @ObservationIgnored private let settings = Settings()
    @ObservationIgnored private var session: DeviceSession?

    init() {
        prefs = settings.values
        Task { await discoveryLoop() }
    }

    private func discoveryLoop() async {
        while !Task.isCancelled {
            if session == nil {
                await tryStartSession()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func tryStartSession() async {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            status = "Allow DeskBridge in Privacy & Security > Accessibility"
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
            status = "Connecting to \(device.serial)…"
            let session = DeviceSession(adb: adb, serial: device.serial, jar: jar, settings: settings)
            session.onStateChange = { [weak self] state in
                Task { @MainActor in self?.apply(state, serial: device.serial) }
            }
            self.session = session
            session.start()
        } catch {
            status = "\(error)"
        }
    }

    private func apply(_ state: DeviceSession.State, serial: String) {
        switch state {
        case .starting: status = "Connecting to \(serial)…"; isActive = false
        case .local: status = "Connected: \(serial)"; isActive = true
        case .remote: status = "Controlling \(serial) (⌃⌥⌘⎋ to release)"; isActive = true
        case let .ended(reason):
            status = reason
            isActive = false
            session = nil // the discovery loop starts a new session
        }
    }
}
