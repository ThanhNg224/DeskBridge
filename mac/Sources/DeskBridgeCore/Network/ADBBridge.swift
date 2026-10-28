import Darwin
import Foundation

public struct AdbDevice: Equatable, Sendable {
    public let serial: String
    public let state: String
    /// Model reported by `adb devices -l` (e.g. "SM N770F"), if any.
    public let model: String?

    public init(serial: String, state: String, model: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
    }

    public var isReady: Bool {
        state == "device"
    }

    public var isWireless: Bool {
        serial.contains(":") || serial.hasSuffix("._adb-tls-connect._tcp") || serial.hasSuffix("._adb._tcp")
    }

    /// Short name for the UI.
    public var displayName: String {
        model ?? serial
    }
}

public enum ADBError: Error, CustomStringConvertible {
    case commandTimedOut
    case operationTimedOut
    case wirelessDeviceNotReady(String)
    case adbNotFound
    case commandFailed(String)
    case badForwardOutput(String)
    case noWifiIPFound
    case invalidWirelessIP
    case invalidWirelessPort
    case wirelessConnectionFailed(String)

    public var description: String {
        switch self {
        case .commandTimedOut: "The ADB command timed out."
        case .operationTimedOut: "The ADB operation timed out."
        case let .wirelessDeviceNotReady(target): "The phone at \(target) is not ready over Wi-Fi."
        case .adbNotFound: "adb not found. Install Android platform-tools or set ANDROID_HOME."
        case let .commandFailed(output): "adb failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .badForwardOutput(output): "Unexpected adb forward output: \(output)"
        case .noWifiIPFound: "Could not find a Wi-Fi IP address on the phone."
        case .invalidWirelessIP: "Enter a valid IPv4 address."
        case .invalidWirelessPort: "Enter a port between 1 and 65535."
        case let .wirelessConnectionFailed(output): "Failed to connect to phone over Wi-Fi: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

public enum WirelessStage: Sendable {
    case readingAddress, preparing, connecting, checkingDevice
}

public struct ADBBridge: Sendable {
    public let adbPath: String
    private var operation: ADBOperation?

    public init(adbPath: String? = nil) throws {
        guard let path = adbPath ?? Self.locate() else { throw ADBError.adbNotFound }
        self.adbPath = path
    }

    public func withOperation(_ operation: ADBOperation) -> ADBBridge {
        var bridge = self
        bridge.operation = operation
        return bridge
    }

    /// Only an IPv4 endpoint can be reconnected with `adb connect`; mDNS serials are not endpoints.
    public static func wirelessEndpoint(serial: String) -> (ip: String, port: Int)? {
        let parts = serial.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = normalizedIPv4(String(parts[0])),
              let port = Int(parts[1]), (1 ... 65535).contains(port)
        else { return nil }
        return (ip, port)
    }

    static func candidatePaths(environment: [String: String], home: String, managed: String) -> [String] {
        var candidates: [String] = []
        if let adb = environment["ADB"] {
            candidates.append(adb)
        }
        if let sdk = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"] {
            candidates.append(sdk + "/platform-tools/adb")
        }
        candidates += [home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        candidates.append(managed)
        return candidates
    }

    public static func locate() -> String? {
        candidatePaths(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
                       managed: ManagedADB.executable.path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Parsing (pure, unit-tested)

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("*"), !line.hasPrefix("List of devices") else { return nil }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return nil }
            let model = parts.dropFirst(2)
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return AdbDevice(serial: String(parts[0]), state: String(parts[1]), model: model)
        }
    }

    public static func parseForwardPort(_ output: String) throws -> Int {
        guard let port = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            throw ADBError.badForwardOutput(output)
        }
        return port
    }

    public static func parseIP(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let device = parts.firstIndex(of: "dev"), parts.indices.contains(device + 1),
               parts[device + 1] == "wlan0",
               let source = parts.firstIndex(of: "src"), parts.indices.contains(source + 1),
               let ip = normalizedIPv4(String(parts[source + 1]))
            {
                return ip
            }
            if parts.first == "inet", parts.count > 1, parts.contains("wlan0"),
               let address = parts[1].split(separator: "/").first,
               let ip = normalizedIPv4(String(address))
            {
                return ip
            }
        }
        return nil
    }

    public static func wirelessTarget(ip: String, port: Int) throws -> String {
        guard let address = normalizedIPv4(ip.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ADBError.invalidWirelessIP
        }
        guard (1 ... 65535).contains(port) else { throw ADBError.invalidWirelessPort }
        return "\(address):\(port)"
    }

    private static func normalizedIPv4(_ ip: String) -> String? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var normalized: [String] = []
        for octet in octets {
            guard !octet.isEmpty, octet.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let value = Int(octet), (0 ... 255).contains(value)
            else { return nil }
            normalized.append(String(value))
        }
        return normalized.joined(separator: ".")
    }

    public static func isConnectSuccessful(output: String) -> Bool {
        let lower = output.lowercased()
        return (lower.contains("connected to") || lower.contains("already connected")) && !lower
            .contains("failed") && !lower.contains("unable")
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
        try Self.parseDevices(run(["devices", "-l"]))
    }

    public func push(serial: String, local: URL, remote: String) throws {
        _ = try run(["-s", serial, "push", local.path, remote])
    }

    /// Lets adb pick a free local port and returns it.
    public func forward(serial: String, abstractSocket: String) throws -> Int {
        try Self.parseForwardPort(run(["-s", serial, "forward", "tcp:0", "localabstract:\(abstractSocket)"]))
    }

    /// Marketing model name (e.g. "SM-N770F"), falling back to the serial.
    public func deviceName(serial: String) -> String {
        let model = (try? run(["-s", serial, "shell", "getprop", "ro.product.model"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? serial : model
    }

    public func deviceIP(serial: String) throws -> String {
        let routeOutput = try addressOutput(["-s", serial, "shell", "ip", "route"])
        if let ip = Self.parseIP(from: routeOutput) {
            return ip
        }
        let addrOutput = try addressOutput(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"])
        if let ip = Self.parseIP(from: addrOutput) {
            return ip
        }
        throw ADBError.noWifiIPFound
    }

    private func addressOutput(_ arguments: [String]) throws -> String {
        do { return try run(arguments) }
        catch ADBError.commandFailed { return "" }
    }

    public func switchToWireless(
        serial: String, port: Int = 5555,
        progress: @Sendable (WirelessStage) -> Void = { _ in }
    ) async throws -> String {
        guard (1 ... 65535).contains(port) else { throw ADBError.invalidWirelessPort }
        let bridge = withOperation(operation ?? ADBOperation())
        progress(.readingAddress)
        let ip = try bridge.deviceIP(serial: serial)
        let target = try Self.wirelessTarget(ip: ip, port: port)
        progress(.preparing)
        _ = try bridge.run(["-s", serial, "tcpip", "\(port)"])
        return try await bridge.awaitWireless(target: target, retryConnection: true, progress: progress)
    }

    public func connectWireless(
        ip: String, port: Int = 5555,
        progress: @Sendable (WirelessStage) -> Void = { _ in }
    ) async throws -> String {
        let target = try Self.wirelessTarget(ip: ip, port: port)
        let bridge = withOperation(operation ?? ADBOperation())
        return try await bridge.awaitWireless(target: target, retryConnection: false, progress: progress)
    }

    private func awaitWireless(
        target: String, retryConnection: Bool,
        progress: @Sendable (WirelessStage) -> Void
    ) async throws -> String {
        var connectionOutput = ""
        var connected = false
        while true {
            try operation?.checkCancellation()
            progress(.connecting)
            do {
                connectionOutput = try run(["connect", target])
                connected = Self.isConnectSuccessful(output: connectionOutput)
                if !connected, !retryConnection {
                    throw ADBError.wirelessConnectionFailed(connectionOutput)
                }
            } catch let ADBError.commandFailed(output) {
                if !retryConnection {
                    throw ADBError.commandFailed(output)
                }
                connectionOutput = output
                connected = false
            }
            if connected {
                progress(.checkingDevice)
                if try devices().contains(where: { $0.serial == target && $0.isReady }) {
                    return target
                }
            }
            // Report the failed stage while the shared operation still has time left.
            guard let operation, operation.remaining > 1 else {
                if connected {
                    throw ADBError.wirelessDeviceNotReady(target)
                }
                throw ADBError.wirelessConnectionFailed(connectionOutput)
            }
            let pauseUntil = ProcessInfo.processInfo.systemUptime + min(1, operation.remaining)
            while ProcessInfo.processInfo.systemUptime < pauseUntil {
                try operation.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @discardableResult
    public func disconnectWireless(serial: String) throws -> String {
        try run(["disconnect", serial])
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
        try operation?.checkCancellation()
        try Task.checkCancellation()
        if adbPath == ManagedADB.executable.path {
            try ManagedADB.ensureServerCompatible(ManagedADB.executable)
        }
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
        try operation?.checkCancellation()
        try Task.checkCancellation()
        if adbPath == ManagedADB.executable.path {
            try ManagedADB.ensureServerCompatible(ManagedADB.executable)
        }
        let commandDeadline = ProcessInfo.processInfo.systemUptime + 10
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deskbridge-adb-\(UUID().uuidString)")
        _ = FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        // A regular file cannot hang while waiting for inherited pipe descriptors to close.
        process.standardOutput = output
        process.standardError = output
        try process.run()
        do {
            while process.isRunning {
                try operation?.checkCancellation()
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime >= commandDeadline {
                    throw ADBError.commandTimedOut
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try operation?.checkCancellation()
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: outputURL)
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ADBError.commandFailed(text) }
        return text
    }
}
