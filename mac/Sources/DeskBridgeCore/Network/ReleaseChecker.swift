import Foundation

/// Checks only when requested, and constructs links to this repository rather than trusting API URLs.
public enum ReleaseChecker {
    public enum Error: Swift.Error { case unavailable, rateLimited, invalidVersion }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private static func version(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), part.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
                return nil
            }
            return Int(part)
        }
        return values.count == 3 ? values : nil
    }

    public static func newerRelease(data: Data, currentVersion: String) throws -> URL? {
        guard let current = version(currentVersion) else { throw Error.invalidVersion }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        let newer = releases.compactMap { release -> (String, [Int])? in
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
                  let value = version(String(release.tag_name.dropFirst())), current.lexicographicallyPrecedes(value)
            else { return nil }
            return (release.tag_name, value)
        }.max { $0.1.lexicographicallyPrecedes($1.1) }
        guard let tag = newer?.0 else { return nil }
        return URL(string: "https://github.com/ThanhNg224/DeskBridge/releases/tag/\(tag)")
    }

    static func response(data: Data, statusCode: Int, currentVersion: String) throws -> URL? {
        if statusCode == 403 || statusCode == 429 {
            throw Error.rateLimited
        }
        guard statusCode == 200, data.count <= 2_000_000 else { throw Error.unavailable }
        return try newerRelease(data: data, currentVersion: currentVersion)
    }

    public static func check(currentVersion: String) async throws -> URL? {
        var request =
            URLRequest(url: URL(string: "https://api.github.com/repos/ThanhNg224/DeskBridge/releases?per_page=100")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Error.unavailable }
        if response.statusCode == 403 || response.statusCode == 429 {
            throw Error.rateLimited
        }
        guard response.statusCode == 200 else { throw Error.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw Error.unavailable }
            data.append(byte)
        }
        return try Self.response(data: data, statusCode: response.statusCode, currentVersion: currentVersion)
    }
}
