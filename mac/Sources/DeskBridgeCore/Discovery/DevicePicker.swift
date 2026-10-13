public enum DevicePick: Equatable, Sendable {
    case none
    /// A device is attached but not usable yet (unauthorized, offline, ...).
    case notReady(AdbDevice)
    case ready(AdbDevice)
}

public enum DevicePicker {
    /// The first ready device; otherwise the first attached one so the UI can say what is wrong with it.
    public static func pick(from devices: [AdbDevice]) -> DevicePick {
        if let ready = devices.first(where: \.isReady) {
            return .ready(ready)
        }
        if let other = devices.first {
            return .notReady(other)
        }
        return .none
    }
}
