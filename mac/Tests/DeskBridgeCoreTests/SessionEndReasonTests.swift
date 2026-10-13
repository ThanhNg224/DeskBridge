@testable import DeskBridgeCore
import Testing

struct SessionEndReasonTests {
    @Test func injectionDeniedIsRecognizedFromTheServerLog() {
        let log = "java.lang.SecurityException: Injecting input events requires the caller to have INJECT_EVENTS"
        #expect(SessionEndReason.connectionLost(serverLog: log).isInjectionDenied)
        #expect(!SessionEndReason.connectionLost(serverLog: "").isInjectionDenied)
        #expect(!SessionEndReason.deviceSilent.isInjectionDenied)
    }

    @Test func descriptionsAreHumanReadableEnglish() {
        #expect(SessionEndReason.connectionLost(serverLog: "").description == "Connection to the device was lost")
        #expect(SessionEndReason.deviceSilent.description == "The device stopped responding")
        #expect(SessionEndReason.adbFailed("adb failed: x").description == "adb failed: x")
    }
}
