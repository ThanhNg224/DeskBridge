import Darwin
@testable import DeskBridge
import Foundation
import os
import Testing

struct ScrcpyProcessTests {
    private func fixture(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("scrcpy")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (directory, executable)
    }

    private func bundledFixture() throws -> (URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = directory.appendingPathComponent("Desk Bridge.app")
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        let resources = bundle.appendingPathComponent("Contents/Resources/scrcpy")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = helpers.appendingPathComponent("scrcpy")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for name in ["scrcpy-server", "scrcpy.png", "disconnected.png"] {
            try Data().write(to: resources.appendingPathComponent(name))
        }
        return (directory, bundle, resources)
    }

    @Test func bundledRuntimeTakesPrecedenceAndOverridesEnvironment() throws {
        let (directory, bundle, resources) = try bundledFixture()
        let (pathDirectory, _) = try fixture("exit 0")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: pathDirectory)
        }
        let config = try ScrcpyLaunchConfiguration.prepare(
            adbPath: "/tmp/chosen adb", serial: "device with spaces",
            environment: ["PATH": pathDirectory.path, "ADB": "/wrong/adb",
                          "SCRCPY_SERVER_PATH": "/wrong/server", "SCRCPY_ICON_DIR": "/wrong/icons"],
            searchDirectories: [pathDirectory.path], bundleURL: bundle
        )
        #expect(config.executableURL.path == bundle.appendingPathComponent("Contents/Helpers/scrcpy").path)
        #expect(config.environment["SCRCPY_SERVER_PATH"] == resources.appendingPathComponent("scrcpy-server").path)
        #expect(config.environment["SCRCPY_ICON_DIR"] == resources.path)
        #expect(config.environment["ADB"] == "/tmp/chosen adb")
        #expect(config.arguments.first == "--serial=device with spaces")
    }

    @Test func incompleteBundleDoesNotFallBackToPath() throws {
        let (directory, bundle, resources) = try bundledFixture()
        let (pathDirectory, _) = try fixture("exit 0")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: pathDirectory)
        }
        let server = resources.appendingPathComponent("scrcpy-server")
        let executable = bundle.appendingPathComponent("Contents/Helpers/scrcpy")
        for missing in [server, executable, resources.appendingPathComponent("scrcpy.png"),
                        resources.appendingPathComponent("disconnected.png")]
        {
            let contents = try Data(contentsOf: missing)
            try FileManager.default.removeItem(at: missing)
            do {
                _ = try ScrcpyLaunchConfiguration.prepare(adbPath: "/bin/true", serial: "x",
                                                          environment: ["PATH": pathDirectory.path],
                                                          searchDirectories: [pathDirectory.path], bundleURL: bundle)
                Issue.record("Expected missing bundle resource to fail: \(missing.lastPathComponent)")
            } catch ScrcpyError.notInstalled {
                // Expected, even when a developer executable is available.
            }
            try contents.write(to: missing)
            if missing == executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: missing.path)
            }
        }
    }

    @Test func standaloneExecutableUsesDeveloperLookup() throws {
        let (directory, executable) = try fixture("exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try ScrcpyLaunchConfiguration.prepare(adbPath: "/bin/true", serial: "x",
                                                           environment: ["PATH": directory.path],
                                                           searchDirectories: [directory.path], bundleURL: directory)
        #expect(config.executableURL == executable.standardizedFileURL)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }

    @Test func finderPathAndArguments() throws {
        let (directory, _) = try fixture("exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try ScrcpyLaunchConfiguration.prepare(adbPath: "/tmp/chosen adb", serial: "a b;$(bad)",
                                                           environment: ["PATH": "/usr/bin:/bin"],
                                                           searchDirectories: [directory.path])
        #expect(config.executableURL.path == directory.appendingPathComponent("scrcpy").path)
        #expect(config.arguments.first == "--serial=a b;$(bad)")
        #expect(config.environment["ADB"] == "/tmp/chosen adb")
        #expect(throws: ScrcpyError.self) {
            try ScrcpyLaunchConfiguration.prepare(adbPath: "/bin/true", serial: "x", environment: [:],
                                                  searchDirectories: [directory.appendingPathComponent("missing").path])
        }
    }

    @Test func launchPassesArgumentsAndEnvironmentAndHandlesImmediateExit() async throws {
        let (directory,
             _) =
            try fixture(
                "i=0; while [ $i -lt 10000 ]; do echo noisy-stderr-line >&2; i=$((i+1)); done; printf '%s\\n' \"$1\" \"$ADB\" > \"$OUT\"; exit 7"
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        let config = try ScrcpyLaunchConfiguration.prepare(adbPath: "/tmp/my adb", serial: "a b;$(bad)",
                                                           environment: ["OUT": output.path],
                                                           searchDirectories: [directory.path])
        let exits = OSAllocatedUnfairLock(initialState: [ScrcpyExit]())
        let process = ScrcpyProcess()
        _ = try await process.start(config) { exit in exits.withLock { $0.append(exit) } }
        try await waitFor { !exits.withLock { $0.isEmpty } }
        #expect(try String(contentsOf: output, encoding: .utf8) == "--serial=a b;$(bad)\n/tmp/my adb\n")
        #expect(exits.withLock { $0.first?.status } == 7)
        #expect(exits.withLock { $0.first?.wasSignalled } == false)
        await process.stop()
    }

    @Test func cancellationBeforeStartAndLaunchFailure() async throws {
        let (directory, executable) = try fixture("exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try ScrcpyLaunchConfiguration.prepare(adbPath: "/bin/true", serial: "x", environment: [:],
                                                           searchDirectories: [directory.path])
        let cancelled = ScrcpyProcess()
        await cancelled.stop()
        await #expect(throws: ScrcpyError.self) { try await cancelled.start(config) { _ in } }
        try FileManager.default.removeItem(at: executable)
        let failed = ScrcpyProcess()
        await #expect(throws: ScrcpyError.self) { try await failed.start(config) { _ in } }
        await failed.stop()
    }

    @Test func stopEscalatesAndOnlyKillsOwnedChild() async throws {
        let (directory, _) = try fixture("trap '' TERM\necho ready > \"$READY\"\nwhile :; do :; done")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready1 = directory.appendingPathComponent("one"), ready2 = directory.appendingPathComponent("two")
        func config(_ ready: URL) throws -> ScrcpyLaunchConfiguration {
            try ScrcpyLaunchConfiguration.prepare(adbPath: "/bin/true", serial: "x",
                                                  environment: ["READY": ready.path],
                                                  searchDirectories: [directory.path])
        }
        let one = ScrcpyProcess(), two = ScrcpyProcess()
        let exits = OSAllocatedUnfairLock(initialState: [ScrcpyExit]())
        let pid1 = try await one.start(config(ready1)) { exit in exits.withLock { $0.append(exit) } }
        let pid2 = try await two.start(config(ready2)) { _ in }
        try await waitFor {
            FileManager.default.fileExists(atPath: ready1.path) && FileManager.default.fileExists(atPath: ready2.path)
        }
        await one.stop()
        #expect(kill(pid1, 0) == -1)
        #expect(kill(pid2, 0) == 0)
        #expect(exits.withLock { $0.first?.wasSignalled } == true)
        #expect(exits.withLock { $0.first?.status } == SIGKILL)
        await two.stop()
    }
}
