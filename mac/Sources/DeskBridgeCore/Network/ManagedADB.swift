import Darwin
import Foundation
import Security
import ZIPFoundation

/// Installs only the Google-signed adb from a ZIP explicitly chosen by the user.
public enum ManagedADB {
    public enum InstallError: Swift.Error { case invalidArchive, invalidSignature, incompatibleServer, commandFailed }
    private static let maxArchive: UInt64 = 128 * 1024 * 1024
    private static let maxEntry: UInt64 = 64 * 1024 * 1024
    private static let maxTotal: UInt64 = 512 * 1024 * 1024

    public static var executable: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBridge/platform-tools/adb")
    }

    static func extractADB(from zip: URL, to output: URL) throws {
        let values = try zip.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0,
              UInt64(size) <= maxArchive else { throw InstallError.invalidArchive }
        let archive = try Archive(url: zip, accessMode: .read)
        var selected: Entry?
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            let path = entry.path
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard count <= 1000, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  !components.contains(where: { $0 == "." || $0 == ".." }), entry.type != .symlink,
                  entry.uncompressedSize <= maxEntry, total <= maxTotal - entry.uncompressedSize
            else {
                throw InstallError.invalidArchive
            }
            total += entry.uncompressedSize
            if path == "platform-tools/adb" {
                guard selected == nil, entry.type == .file, entry.uncompressedSize > 0 else {
                    throw InstallError.invalidArchive
                }
                selected = entry
            }
        }
        guard let selected else { throw InstallError.invalidArchive }
        guard FileManager.default
            .createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw InstallError.invalidArchive
        }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        var written: UInt64 = 0
        let checksum = try archive.extract(selected) { chunk in
            let size = UInt64(chunk.count)
            guard size <= maxEntry - written, written + size <= selected.uncompressedSize else {
                throw InstallError.invalidArchive
            }
            try file.write(contentsOf: chunk)
            written += size
        }
        guard checksum == selected.checksum, written == selected.uncompressedSize else {
            throw InstallError.invalidArchive
        }
    }

    static func verifyGoogleSignature(_ url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError.invalidSignature
        }
        let requirement = "anchor apple generic and identifier \"adb\" and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        var expected: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
              let expected,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), expected) == errSecSuccess
        else { throw InstallError.invalidSignature }
        guard try supportsArm64(url) else { throw InstallError.invalidSignature }
    }

    static func supportsArm64(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try [UInt8](handle.read(upToCount: 4096) ?? Data())
        func number(_ offset: Int, _ bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let slice = bytes[offset ..< offset + 4]
            return (bigEndian ? Array(slice) : Array(slice.reversed())).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard bytes.count >= 8, let magic = number(0, true) else { return false }
        let arm64: UInt32 = 0x0100_000C
        if magic == 0xCFFA_EDFE {
            return number(4, false) == arm64
        }
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF, let count = number(4, true), count <= 64 else {
            return false
        }
        let stride = magic == 0xCAFE_BABF ? 32 : 20
        return (0 ..< Int(count)).contains { number(8 + $0 * stride, true) == arm64 }
    }

    /// host:version is queried without starting, stopping, or replacing the shared server.
    static func serverVersion(port: UInt16) throws -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw InstallError.incompatibleServer }
        defer { close(fd) }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) }
        }
        if result != 0 {
            if errno == ECONNREFUSED {
                return nil
            }
            throw InstallError.incompatibleServer
        }
        let request = Array("000chost:version".utf8)
        let sent = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { throw InstallError.incompatibleServer }
        func readBytes(_ count: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var received = 0
            while received < count {
                let amount = bytes.withUnsafeMutableBytes { recv(
                    fd,
                    $0.baseAddress!.advanced(by: received),
                    count - received,
                    0
                ) }
                guard amount > 0 else { throw InstallError.incompatibleServer }
                received += amount
            }
            return bytes
        }
        guard try String(decoding: readBytes(4), as: UTF8.self) == "OKAY",
              let count = try Int(String(decoding: readBytes(4), as: UTF8.self), radix: 16), count == 4,
              let version = try Int(String(decoding: readBytes(count), as: UTF8.self), radix: 16)
        else { throw InstallError.incompatibleServer }
        return version
    }

    static func clientVersion(_ url: URL) throws -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = url
        process.arguments = ["version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let line = String(data: output, encoding: .utf8)?.split(separator: "\n").first,
              line.hasPrefix("Android Debug Bridge version 1.0."),
              let version = Int(line.split(separator: ".").last ?? "") else { throw InstallError.commandFailed }
        return version
    }

    public static func ensureServerCompatible(_ adb: URL) throws {
        guard ProcessInfo.processInfo.environment["ADB_SERVER_SOCKET"]?.isEmpty != false else {
            throw InstallError.incompatibleServer
        }
        let client = try clientVersion(adb)
        try validateVersions(client: client, server: serverVersion(port: DeviceWatcher.defaultPort))
    }

    static func validateVersions(client: Int, server: Int?) throws {
        if let server, server != client {
            throw InstallError.incompatibleServer
        }
    }

    public static func install(from zip: URL) throws {
        try install(from: zip, target: executable)
    }

    static func install(from zip: URL, target: URL) throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        try manager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stage = parent.appendingPathComponent(".install-\(UUID().uuidString)")
        try manager.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: stage) }
        let candidate = stage.appendingPathComponent("adb")
        try extractADB(from: zip, to: candidate)
        try verifyGoogleSignature(candidate)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        try ensureServerCompatible(candidate)
        guard rename(candidate.path, target.path) == 0 else { throw InstallError.commandFailed }
    }
}
