import DeskBridgeCore

/// What the first-run checklist shows. Updated on every discovery tick.
struct SetupState: Equatable {
    enum Device: Equatable {
        case none
        /// Several phones are ready and none is chosen yet.
        case choose(Int)
        case notAuthorized(String)
        case waiting(String)
        case ready(String)
    }

    /// Phones that ADB currently reports as ready.
    var phones: [AdbDevice] = []
    var accessibility = false
    var adbFound = true
    var device = Device.none

    var isComplete: Bool {
        guard accessibility, adbFound, case .ready = device else { return false }
        return true
    }
}
