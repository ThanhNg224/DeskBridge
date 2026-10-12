import Foundation

public struct AdbDevice: Equatable, Sendable {
    public let serial: String
    public let state: String
    public var isReady: Bool {
        state == "device"
    }
}

public enum ADBError: Error, CustomStringConvertible {
    case adbNotFound
    case commandFailed(String)
    case badForwardOutput(String)

    public var description: String {
        switch self {
        case .adbNotFound: "adb not found. Install Android platform-tools or set ANDROID_HOME."
        case let .commandFailed(output): "adb failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .badForwardOutput(output): "Unexpected adb forward output: \(output)"
        }
    }
}

public struct ADBBridge: Sendable {
    public let adbPath: String

    public init(adbPath: String? = nil) throws {
        guard let path = adbPath ?? Self.locate() else { throw ADBError.adbNotFound }
        self.adbPath = path
    }

    public static func locate() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let adb = env["ADB"] {
            candidates.append(adb)
        }
        if let sdk = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] {
            candidates.append(sdk + "/platform-tools/adb")
        }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Parsing (pure, unit-tested)

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            return AdbDevice(serial: String(parts[0]), state: String(parts[1]))
        }
    }

    public static func parseForwardPort(_ output: String) throws -> Int {
        guard let port = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            throw ADBError.badForwardOutput(output)
        }
        return port
    }

    /// Local ports of leftover DeskBridge forwards for `serial` (left behind when the app was killed).
    public static func staleForwardPorts(in output: String, serial: String) -> [Int] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[0] == serial,
                  parts[1].hasPrefix("tcp:"), parts[2].hasPrefix("localabstract:deskbridge-")
            else { return nil }
            return Int(parts[1].dropFirst(4))
        }
    }

    // MARK: - Commands

    public func devices() throws -> [AdbDevice] {
        try Self.parseDevices(run(["devices"]))
    }

    public func push(serial: String, local: URL, remote: String) throws {
        _ = try run(["-s", serial, "push", local.path, remote])
    }

    /// Lets adb pick a free local port and returns it.
    public func forward(serial: String, abstractSocket: String) throws -> Int {
        try Self.parseForwardPort(run(["-s", serial, "forward", "tcp:0", "localabstract:\(abstractSocket)"]))
    }

    public func removeStaleForwards(serial: String) {
        guard let list = try? run(["forward", "--list"]) else { return }
        for port in Self.staleForwardPorts(in: list, serial: serial) {
            removeForward(serial: serial, port: port)
        }
    }

    public func removeForward(serial: String, port: Int) {
        _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(port)"])
    }

    /// Long-lived `adb shell` process; stderr is piped so the caller can surface server errors.
    public func spawnShell(serial: String, command: String) throws -> (process: Process, stderr: Pipe) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, "shell", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        return (process, stderr)
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile() // read before wait: avoids a full-pipe deadlock
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ADBError.commandFailed(text) }
        return text
    }
}
