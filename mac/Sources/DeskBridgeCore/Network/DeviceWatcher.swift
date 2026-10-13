import Foundation
import os

/// Asks the adb server to track devices (`host:track-devices`) and calls `onChange` whenever it reports that the device
/// list changed (a phone plugged in, unplugged or its state changed), so nothing has to poll for phones. The server
/// stays quiet in between, so an idle app does not wake up. It talks to the server over its TCP port directly: no
/// child process that could outlive the app. If the connection ends (the adb server was killed or restarted) it
/// reconnects, starting the server first when it is not running; `onChange` is also called then, since the list may
/// have changed unseen.
public final class DeviceWatcher: @unchecked Sendable {
    /// The adb server port: `ANDROID_ADB_SERVER_PORT` or 5037.
    public static var defaultPort: UInt16 {
        ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"].flatMap(UInt16.init) ?? 5037
    }

    private let adbPath: String
    private let port: UInt16
    private let restartDelay: TimeInterval
    private let queue = DispatchQueue(label: "deskbridge.devicewatcher")
    private let alive = OSAllocatedUnfairLock(initialState: false)
    private var connection: Connection? // queue only
    private var stopped = true // queue only
    private var onChange: (@Sendable () -> Void)? // queue only

    public init(adbPath: String, port: UInt16 = DeviceWatcher.defaultPort, restartDelay: TimeInterval = 2) {
        self.adbPath = adbPath
        self.port = port
        self.restartDelay = restartDelay
    }

    /// True while connected to the adb server, i.e. while polling for phones is not needed.
    public var isAlive: Bool {
        alive.withLock { $0 }
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.onChange = onChange
            self.launch()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.onChange = nil
            self.connection?.cancel()
            self.connection = nil
            self.alive.withLock { $0 = false }
        }
    }

    private func launch() {
        guard !stopped, connection == nil else { return }
        let connection = Connection(port: port, queue: queue)
        self.connection = connection
        let reachedServer = OSAllocatedUnfairLock(initialState: false)
        connection.onReady = { [weak self, weak connection] in
            reachedServer.withLock { $0 = true }
            self?.alive.withLock { $0 = true }
            connection?.send(Self.request("host:track-devices"))
        }
        connection.onData = { [weak self] _ in self?.onChange?() }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            self.connection = nil
            alive.withLock { $0 = false }
            guard !stopped else { return }
            if reachedServer.withLock({ $0 }) {
                onChange?()
            } else {
                _ = try? ADBBridge(adbPath: adbPath).run(["start-server"]) // refused: the server is not running
            }
            queue.asyncAfter(deadline: .now() + restartDelay) { self.launch() }
        }
        connection.start()
    }

    /// adb host protocol: four hex digits of length, then the request.
    static func request(_ payload: String) -> Data {
        Data((String(format: "%04x", payload.utf8.count) + payload).utf8)
    }
}
