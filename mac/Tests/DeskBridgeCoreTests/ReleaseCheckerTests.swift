@testable import DeskBridgeCore
import Foundation
import Testing

struct ReleaseCheckerTests {
    @Test func findsNewestStableMacReleaseAndConstructsTrustedLink() throws {
        let json = """
        [{"tag_name":"v1.9.0","draft":false,"prerelease":false},
         {"tag_name":"v1.10.0","draft":false,"prerelease":false},
         {"tag_name":"windows-v9.0.0","draft":false,"prerelease":false},
         {"tag_name":"v9.0.0","draft":false,"prerelease":true},
         {"tag_name":"v8.0.0","draft":true,"prerelease":false},
         {"tag_name":"v2.0.0/../../other","draft":false,"prerelease":false}]
        """
        let result = try ReleaseChecker.newerRelease(data: Data(json.utf8), currentVersion: "1.8.0")
        #expect(result?.absoluteString == "https://github.com/ThanhNg224/DeskBridge/releases/tag/v1.10.0")
        #expect(try ReleaseChecker.newerRelease(data: Data(json.utf8), currentVersion: "1.10.0") == nil)
    }

    @Test func rejectsInvalidResponseAndCurrentVersion() {
        #expect(throws: (any Error).self) {
            try ReleaseChecker.newerRelease(data: Data("{}".utf8), currentVersion: "1.1.7")
        }
        #expect(throws: (any Error).self) {
            try ReleaseChecker.newerRelease(data: Data("[]".utf8), currentVersion: "unknown")
        }
    }

    @Test func rejectsRateLimitedAndFailedResponses() {
        for code in [403, 429, 500] {
            #expect(throws: ReleaseChecker.Error.self) {
                try ReleaseChecker.response(data: Data("[]".utf8), statusCode: code, currentVersion: "1.1.7")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DESKBRIDGE_UPDATE_TEST"] != nil))
    func liveCheckReturnsAProjectRelease() async throws {
        let url = try await ReleaseChecker.check(currentVersion: "0.0.0")
        #expect(url?.host == "github.com")
        #expect(url?.path.hasPrefix("/ThanhNg224/DeskBridge/releases/tag/v") == true)
    }
}
