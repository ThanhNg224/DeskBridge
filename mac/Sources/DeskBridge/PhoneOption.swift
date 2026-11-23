import CryptoKit
import DeskBridgeCore
import Foundation

struct PhoneOption: Identifiable {
    enum ID: Hashable {
        case physical(String)
        case transport(String)
    }

    let id: ID
    let phone: AdbDevice
    let name: String
    let identifier: String?
    let isSelected: Bool

    static func make(from phones: [AdbDevice], selectedSerial: String?, selectedIdentity: String?) -> [Self] {
        let identities = Dictionary(grouping: phones.compactMap(\.physicalID), by: { $0 })
        let unnamed = String(localized: "Android phone")
        let names = Dictionary(grouping: phones, by: { $0.friendlyName ?? $0.model ?? unnamed })
        return phones.map { phone in
            let id: ID = if let identity = phone.physicalID, identities[identity]?.count == 1 {
                .physical(identity)
            } else {
                .transport(phone.serial)
            }
            let name = phone.friendlyName ?? phone.model ?? unnamed
            let identifier: String?
            if names[name, default: []].count > 1 {
                // Use the same short identifier across transport changes when identity is known.
                let value: String = switch id {
                case let .physical(identity), let .transport(identity): identity
                }
                identifier = SHA256.hash(data: Data(value.utf8)).prefix(3)
                    .map { String(format: "%02X", $0) }.joined()
            } else {
                identifier = nil
            }
            let isSelected = switch id {
            case let .physical(identity):
                selectedIdentity == identity || (selectedIdentity == nil && selectedSerial == phone.serial)
            case .transport:
                selectedSerial == phone.serial && (selectedIdentity == nil || selectedIdentity == phone.physicalID)
            }
            return Self(id: id, phone: phone, name: name, identifier: identifier, isSelected: isSelected)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return ($0.identifier ?? "", $0.phone.serial) < ($1.identifier ?? "", $1.phone.serial)
        }
    }
}
