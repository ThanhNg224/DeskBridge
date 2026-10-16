# Wireless ADB Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Enable wireless ADB connection features in DeskBridge, including 1-click "Switch to Wi-Fi", manual IP/Port connection, wireless device status badges, and updated onboarding/documentation.

**Architecture:** Extend `ADBBridge` with device IP extraction (`ip route`/`ip addr`), `tcpip`, `connect`, and `disconnect` commands. Integrate these into `AppModel` and `SettingsView` with progress/error feedback, while updating `SetupChecklist` and documentation to accurately communicate wireless and USB support.

**Tech Stack:** Swift 6, AppKit, SwiftUI, ADB CLI (`platform-tools`), XCTest.

## Global Constraints

- Swift 6 strict concurrency (`Sendable`, main-thread isolation where required for UI).
- Work in current Git branch and working tree.
- Follow existing formatting conventions (`swiftformat mac`).
- All changes must pass `scripts/check.sh` (shellcheck, swiftformat lint, server tests, swift build, swift test).

---

### Task 1: Core Wireless Device Helpers & IP Parsing (TDD)

**Files:**
- Modify: `mac/Sources/DeskBridgeCore/Network/ADBBridge.swift:1-40`
- Test: `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift`

**Interfaces:**
- Produces:
  - `AdbDevice.isWireless: Bool`
  - `ADBError.noWifiIPFound`
  - `ADBError.wirelessConnectionFailed(String)`
  - `ADBBridge.parseIP(from: String) -> String?`

- [x] **Step 1: Write failing tests for `isWireless` and `parseIP`**

Add tests to `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift`:

```swift
@Test func isWirelessDistinguishesUsbAndWifi() {
    let usbDevice = AdbDevice(serial: "RF8NA2EZKZK", state: "device")
    #expect(!usbDevice.isWireless)

    let wifiDevice = AdbDevice(serial: "192.168.1.50:5555", state: "device")
    #expect(wifiDevice.isWireless)
}

@Test func parseIPExtractsWlanAddress() {
    let routeOutput = """
    192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.120
    default via 192.168.1.1 dev wlan0
    """
    #expect(ADBBridge.parseIP(from: routeOutput) == "192.168.1.120")

    let addrOutput = """
    inet 192.168.1.125/24 brd 192.168.1.255 scope global wlan0
    """
    #expect(ADBBridge.parseIP(from: addrOutput) == "192.168.1.125")

    let emptyOutput = ""
    #expect(ADBBridge.parseIP(from: emptyOutput) == nil)
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: FAIL (missing `isWireless`, `parseIP`)

- [x] **Step 3: Implement `isWireless`, error cases, and `parseIP` in `ADBBridge.swift`**

Update `mac/Sources/DeskBridgeCore/Network/ADBBridge.swift`:
```swift
extension AdbDevice {
    public var isWireless: Bool {
        serial.contains(":")
    }
}
```

Add to `ADBError`:
```swift
case noWifiIPFound
case wirelessConnectionFailed(String)
```
Update `description`:
```swift
case .noWifiIPFound: "Could not find a Wi-Fi IP address on the phone."
case let .wirelessConnectionFailed(output): "Failed to connect to phone over Wi-Fi: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
```

Add pure static parsing function:
```swift
public static func parseIP(from output: String) -> String? {
    // Check "src <ip>" from `ip route`
    if let srcRange = output.range(of: "src ") {
        let remainder = output[srcRange.upperBound...]
        let token = remainder.split(whereSeparator: \.isWhitespace).first
        if let ip = token.map(String.init), ip.split(separator: ".").count == 4 {
            return ip
        }
    }
    // Check "inet <ip>/" from `ip addr`
    if let inetRange = output.range(of: "inet ") {
        let remainder = output[inetRange.upperBound...]
        let token = remainder.split(separator: "/").first?.trimmingCharacters(in: .whitespaces)
        if let ip = token, ip.split(separator: ".").count == 4 {
            return ip
        }
    }
    return nil
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add mac/Sources/DeskBridgeCore/Network/ADBBridge.swift mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift
git commit -m "feat(core): add AdbDevice.isWireless and ADBBridge.parseIP"
```

---

### Task 2: Wireless Commands in `ADBBridge`

**Files:**
- Modify: `mac/Sources/DeskBridgeCore/Network/ADBBridge.swift`
- Test: `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift`

**Interfaces:**
- Consumes:
  - `ADBBridge.parseIP(from: String) -> String?`
- Produces:
  - `ADBBridge.deviceIP(serial: String) throws -> String`
  - `ADBBridge.switchToWireless(serial: String, port: Int) async throws -> String`
  - `ADBBridge.connectWireless(ip: String, port: Int) async throws -> String`
  - `ADBBridge.disconnectWireless(serial: String) async throws -> String`

- [x] **Step 1: Write tests for wireless connection validation**

Add unit test in `mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift` testing success vs failure output parsing for `adb connect`:

```swift
@Test func parseConnectOutputDetectsErrors() {
    let successOutput = "connected to 192.168.1.50:5555\n"
    let alreadyConnected = "already connected to 192.168.1.50:5555\n"
    let failureOutput = "failed to connect to 192.168.1.50:5555: Connection refused\n"

    #expect(ADBBridge.isConnectSuccessful(output: successOutput))
    #expect(ADBBridge.isConnectSuccessful(output: alreadyConnected))
    #expect(!ADBBridge.isConnectSuccessful(output: failureOutput))
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: FAIL (`isConnectSuccessful` not defined)

- [x] **Step 3: Implement `isConnectSuccessful` and wireless methods in `ADBBridge.swift`**

In `ADBBridge.swift`:
```swift
public static func isConnectSuccessful(output: String) -> Bool {
    let lower = output.lowercased()
    return (lower.contains("connected to") || lower.contains("already connected")) && !lower.contains("failed") && !lower.contains("unable")
}

public func deviceIP(serial: String) throws -> String {
    let routeOutput = (try? run(["-s", serial, "shell", "ip", "route"])) ?? ""
    if let ip = Self.parseIP(from: routeOutput) { return ip }
    let addrOutput = (try? run(["-s", serial, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"])) ?? ""
    if let ip = Self.parseIP(from: addrOutput) { return ip }
    throw ADBError.noWifiIPFound
}

public func switchToWireless(serial: String, port: Int = 5555) async throws -> String {
    let ip = try deviceIP(serial: serial)
    _ = try run(["-s", serial, "tcpip", "\(port)"])
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let target = "\(ip):\(port)"
    let output = try run(["connect", target])
    guard Self.isConnectSuccessful(output: output) else {
        throw ADBError.wirelessConnectionFailed(output)
    }
    return target
}

public func connectWireless(ip: String, port: Int = 5555) async throws -> String {
    let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedIP.isEmpty else { throw ADBError.commandFailed("IP address cannot be empty") }
    let target = "\(trimmedIP):\(port)"
    let output = try run(["connect", target])
    guard Self.isConnectSuccessful(output: output) else {
        throw ADBError.wirelessConnectionFailed(output)
    }
    return target
}

@discardableResult
public func disconnectWireless(serial: String) async throws -> String {
    try run(["disconnect", serial])
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd mac && swift test --filter ADBBridgeTests`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add mac/Sources/DeskBridgeCore/Network/ADBBridge.swift mac/Tests/DeskBridgeCoreTests/ADBBridgeTests.swift
git commit -m "feat(core): implement switchToWireless, connectWireless, and disconnectWireless"
```

---

### Task 3: AppModel Wireless State & Actions

**Files:**
- Modify: `mac/Sources/DeskBridge/AppModel.swift`

**Interfaces:**
- Consumes:
  - `ADBBridge.switchToWireless`, `connectWireless`, `disconnectWireless`
- Produces:
  - `AppModel.wirelessIP: String`
  - `AppModel.wirelessPort: String`
  - `AppModel.isConnectingWireless: Bool`
  - `AppModel.isSwitchingToWireless: Bool`
  - `AppModel.wirelessErrorMessage: String?`
  - `AppModel.switchToWireless(serial: String)`
  - `AppModel.connectWireless()`
  - `AppModel.disconnectWireless(serial: String)`

- [x] **Step 1: Inspect `AppModel.swift` to identify state & concurrency patterns**

Read `mac/Sources/DeskBridge/AppModel.swift`. Note the `@MainActor` isolation and how `adb` is accessed.

- [x] **Step 2: Add wireless state properties and action methods to `AppModel.swift`**

Add properties:
```swift
var wirelessIP: String = ""
var wirelessPort: String = "5555"
var isConnectingWireless: Bool = false
var isSwitchingToWireless: Bool = false
var wirelessErrorMessage: String? = nil
```

Add methods:
```swift
func switchToWireless(serial: String) {
    guard let adb else { return }
    isSwitchingToWireless = true
    wirelessErrorMessage = nil
    Task {
        do {
            let newSerial = try await adb.switchToWireless(serial: serial)
            prefs.preferredSerial = newSerial
            isSwitchingToWireless = false
        } catch {
            wirelessErrorMessage = "\(error)"
            isSwitchingToWireless = false
        }
    }
}

func connectWireless() {
    guard let adb else { return }
    isConnectingWireless = true
    wirelessErrorMessage = nil
    let ip = wirelessIP
    let port = Int(wirelessPort) ?? 5555
    Task {
        do {
            let target = try await adb.connectWireless(ip: ip, port: port)
            prefs.preferredSerial = target
            wirelessIP = ""
            isConnectingWireless = false
        } catch {
            wirelessErrorMessage = "\(error)"
            isConnectingWireless = false
        }
    }
}

func disconnectWireless(serial: String) {
    guard let adb else { return }
    Task {
        do {
            _ = try await adb.disconnectWireless(serial: serial)
            if prefs.preferredSerial == serial {
                prefs.preferredSerial = nil
            }
        } catch {
            wirelessErrorMessage = "\(error)"
        }
    }
}
```

- [x] **Step 3: Run build and tests to verify compiling**

Run: `cd mac && swift test`
Expected: PASS

- [x] **Step 4: Commit**

```bash
git add mac/Sources/DeskBridge/AppModel.swift
git commit -m "feat(app): add wireless connection actions to AppModel"
```

---

### Task 4: UI Integration in SettingsView, SetupChecklist, and StatusText

**Files:**
- Modify: `mac/Sources/DeskBridge/Views/SettingsView.swift`
- Modify: `mac/Sources/DeskBridge/Views/SetupChecklist.swift`
- Modify: `mac/Sources/DeskBridge/StatusText.swift`
- Modify: `mac/Resources/vi.lproj/Localizable.strings`

**Interfaces:**
- Consumes:
  - `AdbDevice.isWireless`
  - `AppModel.switchToWireless`, `connectWireless`, `disconnectWireless`
  - `AppModel.wirelessIP`, `wirelessPort`, etc.

- [x] **Step 1: Update `StatusText.swift` and `SetupChecklist.swift`**

In `mac/Sources/DeskBridge/StatusText.swift`:
```swift
static let noDevice = String(localized: "Connect an Android phone via USB or Wi-Fi with debugging enabled")
```

In `mac/Sources/DeskBridge/Views/SetupChecklist.swift`:
```swift
case .none:
    row(ok: false, title: "No phone found", hint: "Connect via USB cable or Wi-Fi (wireless debugging).") { EmptyView() }
```

- [x] **Step 2: Update `SettingsView.swift` Phone section**

Enhance the Phone section in `SettingsView.swift`:
- Show Phone section always or when phones exist / for wireless connection.
- In the Phone Picker:
  `Text("\(phone.displayName) [\(phone.isWireless ? "Wi-Fi" : "USB")]").tag(String?.some(phone.serial))`
- Under the picker, display context actions for the selected/active device:
  - If USB device selected:
    `Button("Switch to Wi-Fi") { model.switchToWireless(serial: serial) }` (disabled if `model.isSwitchingToWireless`, with progress indicator)
  - If Wi-Fi device selected:
    `Button("Disconnect Wi-Fi") { model.disconnectWireless(serial: serial) }`
- Add a "Connect via Wi-Fi" subsection:
  - Text fields for IP and Port.
  - "Connect" button (disabled if `model.wirelessIP.isEmpty` or `model.isConnectingWireless`).
  - Error banner if `model.wirelessErrorMessage != nil`.

- [x] **Step 3: Update `Localizable.strings` (vi)**

Add Vietnamese translations for:
- "Connect an Android phone via USB or Wi-Fi with debugging enabled" = "Kết nối điện thoại Android qua USB hoặc Wi-Fi và bật gỡ lỗi";
- "Connect via USB cable or Wi-Fi (wireless debugging)." = "Cắm cáp USB hoặc kết nối qua Wi-Fi (gỡ lỗi không dây).";
- "Connect via Wi-Fi" = "Kết nối qua Wi-Fi";
- "Switch to Wi-Fi" = "Chuyển sang Wi-Fi";
- "Disconnect Wi-Fi" = "Ngắt kết nối Wi-Fi";
- "IP Address" = "Địa chỉ IP";
- "Port" = "Cổng";
- "Connect" = "Kết nối";

- [x] **Step 4: Format and run tests**

Run: `swiftformat mac && cd mac && swift test`
Expected: PASS

- [x] **Step 5: Commit**

```bash
git add mac/Sources/DeskBridge/Views/SettingsView.swift mac/Sources/DeskBridge/Views/SetupChecklist.swift mac/Sources/DeskBridge/StatusText.swift mac/Resources/vi.lproj/Localizable.strings
git commit -m "feat(ui): add wireless connection controls and update setup texts"
```

---

### Task 5: Documentation Updates & Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`

- [x] **Step 1: Update `README.md`**

Replace "USB only" restrictions with accurate descriptions:
- Clarify that DeskBridge connects over USB (for ~1ms ultra-low latency) or Wi-Fi (for wireless convenience).
- Update the FAQ section answering "Can I use it without a cable?": Explain that Wi-Fi connection is supported via the in-app "Switch to Wi-Fi" or "Connect via Wi-Fi" features.

- [x] **Step 2: Update `docs/ARCHITECTURE.md`**

Update the architecture document:
- Note that `DeviceSession` communicates with the local abstract socket over an ADB forward, which transparently works over both USB and TCP/IP (Wi-Fi) ADB connections.
- Document measured latency difference (USB ~1ms vs Wi-Fi ~2-5ms depending on router).

- [x] **Step 3: Run full verification script**

Run: `./scripts/check.sh`
Expected: All stages PASS (shellcheck, swiftformat lint, server tests, build jar, swift build, swift test).

- [x] **Step 4: Commit**

```bash
git add README.md docs/ARCHITECTURE.md
git commit -m "docs: document wireless ADB support in README and architecture"
```
