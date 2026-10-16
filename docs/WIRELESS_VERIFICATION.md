# Wireless ADB verification — 2026-10-16

## Result

The code checks and packaged-app connection scenarios pass. The Wi-Fi latency gate remains **failed** on this network; its 25 ms p95 threshold has not been changed. These measurements do not establish end-to-end mouse or keyboard latency.

## Environment and method

- Mac: macOS 27.0.1 (26A434), Apple M5; signed release app built with `scripts/package_app.sh` using the existing DeskBridge Dev identity.
- ADB: platform-tools 37.0.1-15733141 (protocol tool version 1.0.41).
- Phone: Samsung SM-N770F, Android 13. USB and legacy ADB TCP/IP were measured on the same phone.
- Network: both hosts on the same local subnet; phone Wi-Fi frequency 5240 MHz, reported link speed 400 Mbps, RSSI −55 dBm. These are observations at measurement time, not controlled radio conditions.
- Each row is 300 sequential protocol PING/PONG samples using the existing `DeviceSmokeTests.pingRoundTripLatency`. DeskBridge was closed for the benchmark to avoid competing sessions or removing its ADB forwards. The jar was supplied explicitly with `DESKBRIDGE_SERVER_JAR`; the debug test binary ran with `--skip-build` after packaging. Resource samples use the signed release app.
- An initial collection was discarded because packaging and tests overlapped and the old ADB daemon could no longer connect to Wi-Fi. A temporary independent daemon connected successfully; restarting the default daemon restored connectivity. No retry/server-reset behavior was added to the app.

## Transport round trips

| Transport | Run | p50 (ms) | p95 (ms) | Max (ms) | p95 < 25 ms |
|---|---:|---:|---:|---:|---|
| USB | 1 | 1.13 | 3.21 | 78.02 | PASS |
| USB | 2 | 1.17 | 4.46 | 61.55 | PASS |
| USB | 3 | 1.06 | 2.76 | 55.10 | PASS |
| WIFI | 1 | 20.81 | 35.30 | 62.47 | FAIL |
| WIFI | 2 | 20.50 | 34.06 | 80.29 | FAIL |
| WIFI | 3 | 20.84 | 41.10 | 68.69 | FAIL |

All three USB runs passed; all three Wi-Fi runs failed the existing gate. A separate 20-packet ICMP check returned 0% loss and min/mean/max 6.526/8.387/10.538 ms. ICMP and ADB RTT measure different paths; this does not isolate the extra ADB delay or prove that the network alone causes it. The input protocol and data-path batching were not changed without a measured code-level cause.

## App resource samples

Each CPU figure uses the change in process CPU time over approximately 10 seconds; RSS is the process resident size, not total physical memory usage.

| State | CPU (one core = 100%) | RSS start → end (MiB) |
|---|---:|---:|
| Previous build, Wi-Fi connected idle | 0.70% | 60.3 → 60.3 |
| New build, Wi-Fi connected idle | 0.20% | 113.2 → 92.6 |
| New build, no device after Disconnect | 0.10% | 106.9 → 106.5 |

The old process had been running longer than the new one, so the RSS samples are not a controlled memory-regression comparison. The new connected sample's RSS declined during observation; the samples do not demonstrate a leak or a memory reduction. No sustained CPU spin was observed after disconnect.

## Functional and visual evidence

- `scripts/check.sh`: shellcheck, SwiftFormat lint, Vietnamese strings validation, Java server tests/build, Swift build/tests all pass. Focused `ADBBridgeTests`: 17 tests pass, including fake executable command construction/order, failure propagation, input validation, missing Wi-Fi address, mixed interfaces and mDNS serials.
- Packaged app: invalid IP and nonnumeric port show inline errors and disable Connect. Enter submits a valid endpoint. A refused port keeps both inputs; a successful manual connection clears IP and resets Port to 5555.
- Disconnect and reconnect work while the master switch is paused; the device list updates. Switch to Wi-Fi succeeds on the real phone and selects the wireless transport.
- The user physically unplugged USB. `adb devices -l` then listed only Wi-Fi, the original app server process remained running, and the app stayed Connected. No USB fallback was available.
- Offscreen rendering used the actual SettingsView at widths 400, 440 and 700 in English and Vietnamese: USB (with stale preference), mDNS Wi-Fi, no device, loading, connection error, invalid port, and multiple devices with no valid preference (42 images). The temporary harness disabled model initialization side effects/discovery and injected fixture operation state; these snapshots are visual evidence, not real-device lifecycle tests. Selection and validation assertions passed in the fixture harness. Live packaged-app UI was also inspected at its existing 440 px width.
- Image fixtures and raw logs are temporary local artifacts under `/tmp/deskbridge-visual-qa/`, `/tmp/deskbridge-final-latency-*.log`, and `/tmp/deskbridge-implementation-check.log`.

`DeviceSmokeTests.enterMoveAndExitRoundTrip` also passed with only the Wi-Fi device present: the protocol entered control, sent relative movement, and received EXIT. The app was paused for this harness test, then its preferred Wi-Fi endpoint and enabled state were restored. Interactive keyboard composition and a long-duration Wi-Fi stability test are outside this verification run. The Wi-Fi p95 gate remains unresolved.
