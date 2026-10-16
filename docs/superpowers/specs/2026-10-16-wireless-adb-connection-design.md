# Wireless ADB Connection & UI Support Design

## Overview
DeskBridge already natively works with wireless ADB connections because its core communication is built entirely on top of the host ADB server (`adb -s <serial> push/forward/shell`). However, user documentation, status text, and setup checklists currently indicate "USB only". Furthermore, users have to open a separate terminal to run `adb tcpip 5555` or `adb connect <ip>:<port>`.

This design adds in-app Wireless ADB features:
1. 1-click **"Switch to Wi-Fi"** when an Android device is connected via USB.
2. Manual **"Connect via Wi-Fi IP"** form in Settings.
3. Wireless device status indicator (`[Wi-Fi]` / `[USB]`) and **Disconnect** button for active wireless devices.
4. Updated onboarding/setup text and documentation to accurately communicate wireless & USB ADB support.

---

## Architecture & Core Changes (`DeskBridgeCore`)

### 1. `AdbDevice` Enhancements
- Add `isWireless: Bool`:
  ```swift
  public var isWireless: Bool {
      serial.contains(":")
  }
  ```
- Helpful for UI badge display and conditional actions (e.g., showing Disconnect on wireless devices, Switch to Wi-Fi on USB devices).

### 2. `ADBBridge` Extensions
- **IP Detection (`deviceIP(serial:) -> String?`)**:
  - Run `adb -s <serial> shell ip route` to detect the wlan0 gateway subnet, or `ip -f inet addr show wlan0`.
  - Extract IPv4 address using regex/split.
- **Switch to Wireless (`switchToWireless(serial:port:) async throws -> String`)**:
  1. Retrieve device IP via `deviceIP(serial:)`. Throw `wirelessNoIPFound` if not found.
  2. Execute `adb -s <serial> tcpip <port>` (default 5555).
  3. Sleep 1 second for adbd restart.
  4. Execute `adb connect <ip>:<port>`.
  5. Return `<ip>:<port>` as the newly established serial.
- **Manual Connect (`connectWireless(ip:port:) async throws`)**:
  - Execute `adb connect <ip>:<port>`.
  - Verify stdout: throws `wirelessConnectionFailed(output)` if output contains "failed" or "unable to connect".
- **Disconnect (`disconnectWireless(serial:) async throws`)**:
  - Execute `adb disconnect <serial>`.

### 3. Parsing & Error Types
- Add cases to `ADBError`:
  - `noWifiIPFound`: "Could not find a Wi-Fi IP address on the phone. Make sure it is connected to Wi-Fi."
  - `wirelessConnectionFailed(String)`: "Failed to connect to phone over Wi-Fi."

---

## App Model & UI Changes (`DeskBridge`)

### 1. `AppModel` Additions
- Fields:
  - `wirelessIP: String = ""`
  - `wirelessPort: String = "5555"`
  - `isConnectingWireless: Bool = false`
  - `isSwitchingToWireless: Bool = false`
  - `wirelessErrorMessage: String? = nil`
- Methods:
  - `func switchToWireless(serial: String)`:
    - Runs `adb.switchToWireless(serial: serial)`.
    - On success: sets `prefs.preferredSerial = newSerial`, clears errors.
    - On failure: sets `wirelessErrorMessage`.
  - `func connectWireless()`:
    - Runs `adb.connectWireless(ip: wirelessIP, port: Int(wirelessPort) ?? 5555)`.
    - On success: clears IP/Port inputs, sets `wirelessErrorMessage = nil`.
    - On failure: sets `wirelessErrorMessage`.
  - `func disconnectWireless(serial: String)`:
    - Runs `adb.disconnectWireless(serial: serial)`.

### 2. `SettingsView.swift` Updates
- **Phone Section**:
  - Enhanced Picker with badges: e.g. `"Galaxy S21 [Wi-Fi]"` or `"Galaxy S21 [USB]"`.
  - If currently selected or attached device is USB:
    - Button: `"Switch to Wi-Fi"` with `ProgressView` during transition.
  - If currently selected or attached device is Wi-Fi:
    - Button: `"Disconnect Wi-Fi"` to remove device.
  - **Manual Connect Section**:
    - Disclosure or inline group: `"Connect via Wi-Fi"`
    - TextField for IP (`192.168.1.xxx`) and Port (`5555`).
    - Button: `"Connect"`.
    - Error message banner if `wirelessErrorMessage` is non-nil.

### 3. Onboarding & Documentation Updates
- `SetupChecklist.swift`:
  - When no phone is found: Hint updated to `"Plug it in via USB or connect over Wi-Fi."`
- `StatusText.swift`:
  - `noDevice`: `"Connect an Android phone via USB or Wi-Fi with debugging enabled"`
- `Localizable.strings` (vi):
  - Translate updated strings into Vietnamese.
- `README.md` & `docs/ARCHITECTURE.md`:
  - Update statements that claimed "USB only".
  - Explain that USB provides lowest latency (~1ms), while Wi-Fi provides cable-free convenience.

---

## Error Handling & Edge Cases
1. **Device has multiple network interfaces / VPN**:
   - `deviceIP` parses `wlan0` specifically to avoid VPN or cellular IPs.
2. **Phone not on same subnet / AP isolation**:
   - `adb connect` times out or fails; error message displayed to user advising to check Wi-Fi network.
3. **Unplugging USB after Switch to Wi-Fi**:
   - `preferredSerial` is updated to the Wi-Fi serial immediately, ensuring session continuity when the USB cable is disconnected.

---

## Testing & Verification
1. **Unit Tests (`DeskBridgeCoreTests`)**:
   - `AdbDeviceTests`: Verify `isWireless` returns true for `ip:port` and false for USB serials.
   - `ADBBridgeWirelessTests`: Test IP address extraction from sample `ip route` / `ip addr` outputs.
   - Test `connect` and `disconnect` command construction and error handling.
2. **Verification Suite**:
   - Run `scripts/check.sh` (shellcheck, swiftformat lint, server tests, swift build, swift test).
