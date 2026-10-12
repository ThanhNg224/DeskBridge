import Foundation
import os

/// A running deskbridge-server on one device plus the adb forward that reaches it.
public final class LaunchedServer: @unchecked Sendable {
    public let serial: String
    public let port: Int
    public let token: String
    private let adb: ADBBridge
    private let process: Process
    private let errorLog = OSAllocatedUnfairLock(initialState: "")

    init(serial: String, port: Int, token: String, adb: ADBBridge, process: Process, stderr: Pipe) {
        self.serial = serial
        self.port = port
        self.token = token
        self.adb = adb
        self.process = process
        let log = errorLog
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            log.withLock { $0 = String(($0 + text).suffix(2000)) }
        }
    }

    public var isRunning: Bool {
        process.isRunning
    }

    /// Last stderr output of the server (e.g. a SecurityException from input injection).
    public var lastError: String {
        errorLog.withLock { $0 }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        adb.removeForward(serial: serial, port: port)
    }
}

extension ADBBridge {
    static let remoteJar = "/data/local/tmp/deskbridge-server.jar"

    /// Pushes the jar, forwards a random abstract socket and starts the server.
    /// The server may need a moment to listen: callers retry the connection.
    public func launchServer(serial: String, jar: URL) throws -> LaunchedServer {
        let socketName = "deskbridge-" + ProtocolEncoder.makeToken().prefix(8)
        let token = ProtocolEncoder.makeToken()

        try push(serial: serial, local: jar, remote: Self.remoteJar)
        let port = try forward(serial: serial, abstractSocket: socketName)
        do {
            let command = "CLASSPATH=\(Self.remoteJar) exec app_process / com.deskbridge.server.ServerMain \(socketName) \(token)"
            let (process, stderr) = try spawnShell(serial: serial, command: command)
            return LaunchedServer(serial: serial, port: port, token: token, adb: self, process: process, stderr: stderr)
        } catch {
            removeForward(serial: serial, port: port)
            throw error
        }
    }
}
