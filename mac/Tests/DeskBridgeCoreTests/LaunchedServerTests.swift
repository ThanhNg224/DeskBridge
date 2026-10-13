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
}
