/// Why a session ended. Core only describes reasons in English (for logs); the app maps them to UI text.
public enum SessionEndReason: Equatable, Sendable, CustomStringConvertible {
    case stopped
    case adbFailed(String)
    /// The event tap could not be created: Accessibility / Input Monitoring is missing.
    case captureDenied
    /// The connection dropped; `serverLog` is the server's stderr (e.g. a SecurityException), may be empty.
    case connectionLost(serverLog: String)
    case deviceSilent
    case protocolError(String)

    public var description: String {
        switch self {
        case .stopped: "Stopped"
        case let .adbFailed(detail): detail
        case .captureDenied: CaptureError.tapCreationFailed.description
        case let .connectionLost(log): log.isEmpty ? "Connection to the device was lost" : log
        case .deviceSilent: "The device stopped responding"
        case let .protocolError(detail): "Protocol error: \(detail)"
        }
    }
}
