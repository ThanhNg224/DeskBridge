/// What the first-run checklist shows. Updated on every discovery tick.
struct SetupState: Equatable {
    enum Device: Equatable {
        case none
        case notAuthorized(String)
        case ready(String)
    }

    var accessibility = false
    var adbFound = true
    var device = Device.none

    var isComplete: Bool {
        guard accessibility, adbFound, case .ready = device else { return false }
        return true
    }
}
