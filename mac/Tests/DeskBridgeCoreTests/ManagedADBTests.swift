@testable import DeskBridgeCore
import Foundation
import Testing
import ZIPFoundation

struct ManagedADBTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func zip(_ url: URL, entries: [(String, Entry.EntryType, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, type, data) in entries {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { offset, size in
                data.subdata(in: Int(offset) ..< min(Int(offset) + size, data.count))
            }
        }
    }

    @Test func extractsOnlyADBAndRejectsUnsignedExecutable() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("tools.zip"), output = dir.appendingPathComponent("output")
        try zip(archive, entries: [("platform-tools/adb", .file, Data("not signed".utf8))])
        try ManagedADB.extractADB(from: archive, to: output)
        #expect(try Data(contentsOf: output) == Data("not signed".utf8))
        #expect(throws: (any Error).self) { try ManagedADB.verifyGoogleSignature(output) }
        #expect(try !(ManagedADB.supportsArm64(output)))
    }

    @Test func rejectsUnsafeOrMissingEntriesAndPreservesExistingTool() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("installed/adb")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: target)
        for (index, entries) in [
            [("platform-tools/adb", Entry.EntryType.file, Data("bad".utf8)), ("../escape", .file, Data("x".utf8))],
            [("platform-tools/adb", .symlink, Data("/tmp/evil".utf8))],
            [("platform-tools/fastboot", .file, Data("x".utf8))],
            [("platform-tools/adb", .file, Data("bad".utf8))],
            [("platform-tools/adb", .file, Data("one".utf8)), ("platform-tools/adb", .file, Data("two".utf8))],
        ].enumerated() {
            let archive = dir.appendingPathComponent("\(index).zip")
            try zip(archive, entries: entries)
            #expect(throws: (any Error).self) { try ManagedADB.install(from: archive, target: target) }
            #expect(try Data(contentsOf: target) == Data("old".utf8))
        }
    }

    @Test func rejectsArchiveWhoseOutputExceedsItsDeclaredSize() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archiveURL = dir.appendingPathComponent("forged.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let payload = Data(repeating: 65, count: 100_000)
        try archive.addEntry(with: "platform-tools/adb", type: .file, uncompressedSize: Int64(payload.count),
                             compressionMethod: .deflate)
        { offset, size in
            payload.subdata(in: Int(offset) ..< min(Int(offset) + size, payload.count))
        }
        var bytes = try Data(contentsOf: archiveURL)
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        let header = try #require(bytes.range(of: signature)?.lowerBound)
        bytes.replaceSubrange(header + 24 ..< header + 28, with: [1, 0, 0, 0])
        try bytes.write(to: archiveURL)
        #expect(throws: (any Error).self) {
            try ManagedADB.extractADB(from: archiveURL, to: dir.appendingPathComponent("output"))
        }
    }

    @Test func verifiesLocallyInstalledGoogleADBIfPresent() throws {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        guard FileManager.default.isExecutableFile(atPath: path.path) else { return }
        try ManagedADB.verifyGoogleSignature(path)
        #expect(try ManagedADB.supportsArm64(path))
        #expect(try ManagedADB.clientVersion(path) > 0)
    }

    @Test func refusesIncompatibleSharedServerWithoutChangingExistingTool() throws {
        try ManagedADB.validateVersions(client: 41, server: nil)
        try ManagedADB.validateVersions(client: 41, server: 41)
        #expect(throws: (any Error).self) { try ManagedADB.validateVersions(client: 41, server: 40) }
    }

    @Test func installsSignedGoogleADBFromZIPWhenAvailable() throws {
        let original = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        guard FileManager.default.isExecutableFile(atPath: original.path) else { return }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archiveURL = dir.appendingPathComponent("official.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "platform-tools/adb", fileURL: original)
        let target = dir.appendingPathComponent("installed/adb")
        let before = try ManagedADB.serverVersion(port: DeviceWatcher.defaultPort)
        try ManagedADB.install(from: archiveURL, target: target)
        #expect(try Data(contentsOf: original) == Data(contentsOf: target))
        #expect(try ManagedADB.serverVersion(port: DeviceWatcher.defaultPort) == before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_DEVICE"] != nil))
    func installedGoogleADBCanListTheConnectedDevice() throws {
        let original = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archiveURL = dir.appendingPathComponent("official.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "platform-tools/adb", fileURL: original)
        let target = dir.appendingPathComponent("installed/adb")
        let before = try ManagedADB.serverVersion(port: DeviceWatcher.defaultPort)
        try ManagedADB.install(from: archiveURL, target: target)
        let devices = try ADBBridge(adbPath: target.path).devices()
        #expect(!devices.filter(\.isReady).isEmpty)
        if let before {
            #expect(try ManagedADB.serverVersion(port: DeviceWatcher.defaultPort) == before)
        }
    }
}
