public enum DevicePick: Equatable, Sendable {
    case none
    /// A device is attached but not usable yet (unauthorized, offline, ...).
    case notReady(AdbDevice)
    case ready(AdbDevice)
    /// Several ready devices and none chosen yet: the user has to pick one.
    case choose([AdbDevice])
}

public enum DevicePicker {
    /// The preferred device if it is ready, the only ready device, or a request to choose between several.
    /// With nothing ready, the first attached device is returned so the UI can say what is wrong with it.
    public static func pick(from devices: [AdbDevice], preferredSerial: String? = nil) -> DevicePick {
        let ready = devices.filter(\.isReady)
        if let preferredSerial, let preferred = ready.first(where: { $0.serial == preferredSerial }) {
            return .ready(preferred)
        }
        switch ready.count {
        case 0: break
        case 1: return .ready(ready[0])
        default: return .choose(ready)
        }
        if let other = devices.first {
            return .notReady(other)
        }
        return .none
    }
}
