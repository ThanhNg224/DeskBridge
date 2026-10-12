# DeskBridge

> Modern, ultra-low latency mouse & keyboard sharing for **macOS (Apple Silicon)** and **Android**.

A spiritual successor to DeskDock built with modern technologies:
- **Zero APK Install on Android**: Runs as a lightweight native daemon via ADB `app_process` (UID 2000 / Shell).
- **Native Hardware Mouse Pointer**: Injects native pointer events directly into Android's `InputManager` at full display refresh rate (90Hz / 120Hz).
- **Sub-millisecond Latency**: Local TCP stream over USB ADB port forward (`adb forward`).
- **Apple Silicon Optimized**: Native Swift 6 menu bar client with `CGEventTap` edge detection.
- **Seamless Key Shortcuts**: Automatic `Cmd` to `Ctrl` remapping.
- **Smart Right-Click**: Default `BACK` action with configurable context menu toggle.

---

## Documentation

- **[System Architecture & Design Decisions](file:///Users/thanhng224/Dev/Personal/GitHub/DeskBridge/docs/ARCHITECTURE.md)**: Full architecture breakdown, security model, and binary protocol specification.
- **[Step-by-Step Implementation Plan](file:///Users/thanhng224/Dev/Personal/GitHub/DeskBridge/docs/IMPLEMENTATION_PLAN.md)**: Actionable, bite-sized tasks ready for execution and code review.

---

## Quick Start (For Developers)

### Prerequisites
- macOS 14+ on Apple Silicon (M1/M2/M3/M4)
- Xcode 16+ & Swift 6
- JDK 17+ and Android SDK with `d8` tool installed
- Android device with **USB Debugging** enabled

### Building & Running
1. Build the Android server daemon:
   ```bash
   ./scripts/build_server.sh
   ```
2. Deploy to a connected Android device:
   ```bash
   ./scripts/deploy_server.sh
   ```
3. Run the macOS client:
   ```bash
   cd mac && swift run
   ```
