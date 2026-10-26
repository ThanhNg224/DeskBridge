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

    /// All ready phones while more than one is attached (the user picks one in Settings).
    var phones: [AdbDevice] = []
    var accessibility = false
    var adbFound = true
    var device = Device.none

    var isComplete: Bool {
        guard accessibility, adbFound, case .ready = device else { return false }
        return true
    }
}
