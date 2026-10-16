# Windows acceptance record

Status: **P3 pending Windows and Android acceptance**. Host implementation and automation are present. Local verification on 2026-10-16 is the baseline recorded below; remote CI evidence will be added when a workflow run is available. Native adapter tests and packaging on Windows remain unverified, and no hardware acceptance is implied by local checks.

Local checks on 2026-10-16 (macOS): 43 core tests and 32 existing Java tests passed; the server JAR built; locked NuGet restore passed; the complete Windows solution cross-built with 0 warnings/errors; self-contained `win-x64` cross-publish passed. The local ZIP is a macOS cross-build artifact, not Windows packaging evidence. None of these checks completes a Windows-runtime gate.

The Windows host targets Windows 11 x64. The existing macOS ARM64 host and Android protocol v1 are separate compatibility boundaries. No server or Mac runtime change is needed for this implementation.

## Evidence boundaries

| Check | Where it runs | What it establishes |
| --- | --- | --- |
| Core regression tests | Mac or Windows | Packet bytes/parser, fake ADB, fake transport, timeouts and cleanup |
| Solution cross-build | Mac | Core, WPF host and Windows tests compile |
| Windows adapter tests | Windows CI | Native struct layouts, pure mapping/geometry, queue and WPF composer event logic |
| Packaged artifact | Windows CI | Self-contained x64 output includes the same-commit Android JAR |
| Opt-in device smoke | Windows PC + Android | Session handshake, enter/move/leave and local heartbeat |
| Interactive matrix below | Windows PC + Android | Actual hooks, cursor handoff, IME, clipboard, DPI and recovery |

Use `windows/scripts/check.ps1`, `package.ps1` and `device-smoke.ps1` as described in [the Windows guide](../windows/README.md). A test that cannot run must be recorded as pending/skipped; it cannot be promoted to runtime evidence.

## Test environment

Fill this table for the exact artifact under test. Do not replace pending values with assumptions.

| Field | Value |
| --- | --- |
| Source commit / artifact URL / ZIP SHA-256 | Pending |
| Windows edition, build, CPU architecture | Pending |
| Android manufacturer/model/version | Pending |
| ADB version / USB cable / connection method | Pending |
| Monitors, physical bounds and DPI percentages | Pending |
| Microsoft input method / UniKey version and settings | Pending |
| App signature / observed Windows warnings | Unsigned implementation; actual warning pending |
| Tester / date | Pending |

## Mandatory scenarios

Record PASS/FAIL, evidence and defect issue for each unchecked row. Use a normal user account, a physical Android 13+ phone, two monitors and a trusted Wi-Fi network.

- [ ] Extract the complete ZIP, launch without .NET/admin, and repeat from a path containing spaces and Vietnamese characters.
- [ ] Missing ADB, custom adb.exe, unauthorized/offline devices, no device, multiple devices and saved preferred device produce correct setup states.
- [ ] USB connect; switch to Wi-Fi; unplug USB; manual paired connection; network loss/reconnect; disconnect only the selected endpoint.
- [ ] Enter and return across all four edges; click, drag, wheel, horizontal scroll and right-click Back/secondary mode. No input leaks into a PC application while remote.
- [ ] Secondary monitor left/right/portrait, negative coordinates, 100/150/200% DPI, primary-monitor changes and unplugging a monitor. Internal edges do not enter Android.
- [ ] Ctrl+C/V/A, arrows/Home/End, function keys, key repeat and modifiers held across handoff. No stuck key/button after return.
- [ ] Microsoft Vietnamese Telex in Samsung Notes and browser input: words, editing accents, Backspace, punctuation, Enter, shortcuts, switching layout, pointer movement and focus loss.
- [ ] UniKey **Unicode Telex**, then **Unicode VNI**, in both input targets: the same cases; no duplicate characters or keystrokes landing in a PC application.
- [ ] Composed mode: pending word followed by mouse movement; committed words followed by pending text and immediate emergency return; rapid exit/re-entry preserves ordering.
- [ ] Clipboard both directions, Unicode/empty text, unchanged clipboard, sharing disabled, non-text local clipboard and a temporarily busy clipboard. No automatic image/file replacement on Windows.
- [ ] Emergency shortcut, quit, cable removal, server exit, transport stall, lock/unlock, UAC, sleep/wake and focus loss all restore local control.
- [ ] Tray open/quit/toggle, English/Vietnamese labels, persisted settings, optional startup and launching a second instance.
- [ ] Task Manager, Alt+Tab and Windows key behavior are recorded. Secure desktop behavior stays within Windows boundaries.

## Performance and stability

- [ ] Run at least 30 minutes, 50 handoffs and 10 disconnect/reconnect cycles; record counts and failures.
- [ ] Record CPU/RSS/process tree before and after reconnect cycles. No busy loop, stale forward or orphan server after cleanup.
- [ ] USB transport P50/P95 measured separately; P95 target ≤25 ms. Record tool, sample count and device state.
- [ ] Wi-Fi P50/P95 and network conditions recorded separately; no automatic 25 ms gate.
- [ ] Manually assess motion/drag responsiveness. PING/PONG is transport evidence only and does not prove end-to-end latency.

## Defects and release candidate

Each defect needs source/artifact, environment, reproducible steps, expected/actual behavior and a severity. Fix control loss, input leakage, stuck keys and data issues first. Add a focused regression when possible, rerun the affected matrix rows plus session smoke, and run relevant Mac checks if shared code changes.

- [ ] Mandatory matrix passes for the exact candidate commit; no unresolved control-loss, stuck-key, incorrect-input or clipboard-data defect.
- [ ] Both Vietnamese input methods pass. Any optional configurations not tested are explicitly listed as unverified.
- [ ] Windows CI, artifact integrity, diagnostics and smoke evidence are linked to the candidate.
- [ ] Unsigned-app warnings and remaining limitations are documented.
- [ ] Candidate metadata uses `windows-v0.1.0-alpha.N`, prerelease status and Windows-specific asset name; Mac latest/release assets are untouched.
- [ ] Publication separately requested. No release is created by checks or packaging scripts.

The [Windows P3 milestone](https://github.com/ThanhNg224/DeskBridge/milestone/3) stays open until these gates have evidence.
