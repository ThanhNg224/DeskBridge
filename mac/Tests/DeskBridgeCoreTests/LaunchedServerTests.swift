@testable import DeskBridgeCore
import Foundation
import Testing

struct LaunchedServerTests {
    /// Regression: once the `adb shell` process ended, the stderr handler kept firing on the empty end-of-stream
    /// read and burnt a whole core until the app quit.
    @Test func stderrHandlerIsRemovedWhenTheProcessEnds() async throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo boom >&2"]
        process.standardError = stderr
        try process.run()
        let server = try LaunchedServer(
            serial: "x", port: 1, token: "t", adb: ADBBridge(adbPath: "/usr/bin/true"), process: process, stderr: stderr
        )

        let deadline = Date().addingTimeInterval(5)
        while stderr.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stderr.fileHandleForReading.readabilityHandler == nil)
        #expect(server.lastError == "boom")
    }

    @Test func cleanupForwardSurvivesStartupCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("commands")
        try "#!/bin/sh\nprintf '%s' \"$*\" > '\(log.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let operation = ADBOperation()
        let adb = try ADBBridge(adbPath: executable.path).withOperation(operation)
        operation.cancel()
        adb.cleanupForward(serial: "USB", port: 43210)
        #expect(try String(contentsOf: log, encoding: .utf8) == "-s USB forward --remove tcp:43210")
    }

    @Test func terminateWaitsForOwnedProcessEvenWhenTermIsIgnored() throws {
        let process = Process(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
        process.standardError = stderr
        try process.run()
        let server = try LaunchedServer(serial: "USB", port: 1, token: "t",
                                        adb: ADBBridge(adbPath: "/usr/bin/true"), process: process, stderr: stderr)
        let start = Date()
        server.terminate()
        #expect(!process.isRunning)
        #expect(Date().timeIntervalSince(start) < 1)
    }
}
