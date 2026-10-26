import DeskBridgeCore
import Foundation

protocol AppSession: AnyObject, Sendable {
    var onStateChange: (@Sendable (DeviceSession.State) -> Void)? { get set }
    func start()
    func stop()
    func stopAndWait()
    func settingsChanged()
}

extension DeviceSession: AppSession {}

enum WirelessRequest: Equatable, Sendable {
    case switchFromUSB(String)
    case connect(String, Int)
    case disconnect(String)
}

enum AppConnectionError: Error { case sessionStartFailed }

/// The connection model's I/O; tests substitute sessions without installing event taps.
struct AppDependencies {
    var adb: @Sendable () throws -> ADBBridge = { try ADBBridge() }
    var devices: @Sendable (ADBBridge) async throws -> [AdbDevice] = { adb in
        try await Task.detached { try adb.devices() }.value
    }

    var wireless: @Sendable (
        ADBBridge, WirelessRequest, @escaping @Sendable (WirelessStage) -> Void
    ) async throws -> String = { adb, request, progress in
        try await Task.detached {
            switch request {
            case let .switchFromUSB(serial):
                return try await adb.switchToWireless(serial: serial, progress: progress)
            case let .connect(ip, port):
                return try await adb.connectWireless(ip: ip, port: port, progress: progress)
            case let .disconnect(serial):
                _ = try adb.disconnectWireless(serial: serial)
                return serial
            }
        }.value
    }

    var session: @MainActor (
        ADBBridge, AdbDevice, URL, Settings, ADBOperation
    ) -> any AppSession = { adb, device, jar, settings, operation in
        DeviceSession(adb: adb, serial: device.serial, jar: jar, settings: settings, operation: operation)
    }

    var accessibility: @MainActor () -> Bool = { Permissions.accessibilityGranted }
    var jar: @Sendable () -> URL? = { ServerJar.locate() }
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
}
