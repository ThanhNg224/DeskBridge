import Foundation

public enum ServerJar {
    /// App bundle resource, `$DESKBRIDGE_SERVER_JAR`, or the dev build output next to `mac/`.
    public static func locate() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "deskbridge-server", withExtension: "jar") {
            candidates.append(bundled)
        }
        if let path = ProcessInfo.processInfo.environment["DESKBRIDGE_SERVER_JAR"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath + "/../server/build/deskbridge-server.jar"))
        return candidates.first { fm.fileExists(atPath: $0.path) }?.standardizedFileURL
    }
}
