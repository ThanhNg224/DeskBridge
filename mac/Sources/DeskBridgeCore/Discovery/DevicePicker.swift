public enum DevicePick: Equatable, Sendable {
    case none
    /// A device is attached but not usable yet (unauthorized, offline, ...).
    case notReady(AdbDevice)
    case ready(AdbDevice)
    /// Several ready devices and none chosen yet: the user has to pick one.
    case choose([AdbDevice])
}

public enum DevicePicker {
    /// Group only an unambiguous pair of USB and Wi-Fi transports with the same identity.
    public static func phones(from devices: [AdbDevice], preferredSerial: String?) -> [AdbDevice] {
        let ready = devices.filter(\.isReady)
        var consumed = Set<String>()
        var result: [AdbDevice] = []
        for device in ready where !consumed.contains(device.serial) {
            let matches = ready.filter { $0.physicalID != nil && $0.physicalID == device.physicalID }
            if matches.count == 2, matches.filter(\.isWireless).count == 1 {
                let chosen = matches.first { $0.serial == preferredSerial } ?? matches.first { !$0.isWireless }!
                result.append(chosen)
                consumed.formUnion(matches.map(\.serial))
            } else {
                result.append(device)
                consumed.insert(device.serial)
            }
        }
        return result
    }

    public static func alternate(for serial: String, identity: String?, in devices: [AdbDevice]) -> AdbDevice? {
        guard let identity, !identity.isEmpty else { return nil }
        let matches = devices.filter { $0.isReady && $0.physicalID == identity }
        guard matches.count == 1, let candidate = matches.first,
              candidate.serial != serial,
              candidate.isWireless != AdbDevice(serial: serial, state: "offline").isWireless else { return nil }
        return candidate
    }

    /// An explicit selection is pinned even when offline. Only the initial selection may be automatic.
    /// With nothing ready, the first attached device is returned so the UI can say what is wrong with it.
    public static func pick(from devices: [AdbDevice], preferredSerial: String? = nil) -> DevicePick {
        let ready = phones(from: devices, preferredSerial: preferredSerial)
        if let preferredSerial {
            let preferred = devices.first { $0.serial == preferredSerial }
                ?? AdbDevice(serial: preferredSerial, state: "offline")
            return preferred.isReady ? .ready(preferred) : .notReady(preferred)
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
