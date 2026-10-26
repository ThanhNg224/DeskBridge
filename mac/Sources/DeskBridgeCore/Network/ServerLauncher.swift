import Darwin
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
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil // end of stream: the process is gone; a kept handler spins at 100% CPU
                return
            }
            let text = String(decoding: data, as: UTF8.self)
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
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                usleep(10000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            let killDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline {
                usleep(10000)
            }
        }
        // Startup's operation may already have been cancelled or expired. Cleanup owns a fresh, bounded command.
        adb.cleanupForward(serial: serial, port: port)
    }
}

extension ADBBridge {
    static let remoteJar = "/data/local/tmp/deskbridge-server.jar"

    /// Resource cleanup must survive cancellation of the operation which allocated the resource.
    func cleanupForward(serial: String, port: Int) {
        if let cleanup = try? ADBBridge(adbPath: adbPath).withOperation(ADBOperation(timeout: 2)) {
            cleanup.removeForward(serial: serial, port: port)
        }
    }

    /// Pushes the jar, forwards a random abstract socket and starts the server.
    /// The server may need a moment to listen: callers retry the connection.
    public func launchServer(serial: String, jar: URL) throws -> LaunchedServer {
        let socketName = "deskbridge-" + ProtocolEncoder.makeToken().prefix(8)
        let token = ProtocolEncoder.makeToken()

        removeStaleForwards(serial: serial)
        try push(serial: serial, local: jar, remote: Self.remoteJar)
        let port = try forward(serial: serial, abstractSocket: socketName)
        do {
            let command = "CLASSPATH=\(Self.remoteJar) exec app_process / com.deskbridge.server.ServerMain \(socketName) \(token)"
            let (process, stderr) = try spawnShell(serial: serial, command: command)
            return LaunchedServer(serial: serial, port: port, token: token, adb: self, process: process, stderr: stderr)
        } catch {
            cleanupForward(serial: serial, port: port)
            throw error
        }
    }
}
