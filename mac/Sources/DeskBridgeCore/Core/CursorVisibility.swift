import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum CursorVisibility {
    /// Lets this (background) app hide the Mac cursor while Android has control.
    /// Uses a private CoreGraphics property, so it is best effort: failure only leaves the cursor visible.
    static func allowHidingInBackground() {
        let connection = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
