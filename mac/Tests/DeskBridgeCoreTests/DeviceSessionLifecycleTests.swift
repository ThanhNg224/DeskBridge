@testable import DeskBridgeCore
import Foundation
import os
import Testing

struct DeviceSessionLifecycleTests {
    @Test func stoppingCancelsAnInFlightStartupCommand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adb"), marker = directory.appendingPathComponent("push")
        let script = """
        #!/bin/sh
        case "$*" in
          'forward --list') exit 0;;
          *) touch '\(marker.path)'; exec /bin/sleep 30;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let session = try DeviceSession(adb: ADBBridge(adbPath: executable.path), serial: "USB",
                                        jar: directory.appendingPathComponent("server.jar"),
                                        settings: Settings(defaults: defaults))
        let states = OSAllocatedUnfairLock(initialState: [DeviceSession.State]())
        session.onStateChange = { state in states.withLock { $0.append(state) } }
        session.start()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let stopped = Date()
        session.stop()
        while !states.withLock({ $0.contains(.ended(.stopped)) }), Date().timeIntervalSince(stopped) < 1 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(states.withLock { $0 == [.ended(.stopped)] })
        session.stopAndWait()
    }
}
