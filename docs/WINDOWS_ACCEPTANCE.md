# Windows acceptance record

Status: **Automated CI and package verification complete; P3 interactive Windows and Android acceptance pending**. This record covers Windows code developed on the permanent `windows` branch; `main` remains the macOS ARM64 source of truth. Remote CI confirms the native automated test jobs and Windows package pipeline passed. It does not verify real hooks, IME, clipboard, device behavior or other physical acceptance scenarios below.

Local checks on 2026-10-16 (macOS): 43 core tests and 32 existing Java tests passed; the server JAR built; locked NuGet restore passed; the complete Windows solution cross-built with 0 warnings/errors; self-contained `win-x64` cross-publish passed. The local ZIP is a macOS cross-build artifact, not Windows packaging evidence. None of these checks completes a Windows-runtime gate.

The Windows host targets Windows 11 x64. The inherited `mac/` snapshot on this branch is not the supported Mac source; use `main` for macOS changes. The Android protocol v1 is a shared compatibility boundary, so shared server or protocol fixes must be ported selectively and tested on both branches.

## Pre-acceptance changes — 2026-10-27

The Windows host now pins the selected device across reconnects and serializes connection, Wi-Fi and settings operations. A newer user request cancels older work and waits for its cleanup. Late results cannot replace the newer selection. Manual disconnect pauses automatic reconnect, and an unavailable selected device stays visible in the picker. ADB commands have an 8-second deadline with a separate bounded process-exit wait on cancellation. Wireless mDNS endpoints use the same classification for disconnect and USB-to-Wi-Fi validation.

The Raw Input thread reuses its mouse buffer. Direct-key pointer packets no longer visit the WPF dispatcher just to check for composed text. These changes remove allocations and a dispatcher hop from those paths; CPU, memory and end-to-end latency improvements have not been measured on Windows. The existing dedicated hook thread and `WM_INPUT` default processing follow Microsoft's [hook guidance](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc) and [cleanup requirements](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-input).

Returning local control invalidates a pending entry; if `ENTER` completes late, it is balanced with `LEAVE` before another visit. Shutdown keeps the input pump alive until ordered text/leave processing and connection teardown finish. New regression coverage includes operation cancellation/cleanup order, rapid selection changes, late Wi-Fi results, unavailable selection, shutdown during disconnect, command timeouts and local process termination. Windows UI orchestration tests use fake input and ADB; they do not install global hooks or connect to a phone.

Local verification on macOS: 55 core tests passed, locked restore succeeded, and the complete solution (including the new Windows orchestration tests) cross-built with zero warnings/errors. The GitHub Actions check on the delivery commit records the Windows test and package results. The mandatory physical matrix remains open.

## Remote CI evidence

Successful [GitHub Actions run](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284) on 2026-10-16, source [`a20a9081809971013deff97bd818b81f345c3f29`](https://github.com/ThanhNg224/DeskBridge/commit/a20a9081809971013deff97bd818b81f345c3f29), on the permanent `windows` branch. The [uploaded artifact](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284/artifacts/12035440464) is `DeskBridge-windows-x64-a20a9081809971013deff97bd818b81f345c3f29` and contains the ZIP.

| CI job | Result |
| --- | --- |
| Ubuntu Java server tests and JAR build | 32 tests passed; JAR build succeeded |
| Windows Release build | Succeeded with 0 warnings and 0 errors |
| Windows core tests | 43 passed |
| Windows adapter and composer tests | 26 passed; no skips |
| Self-contained `win-x64` package and artifact upload | Succeeded |

These results establish automated checks and package production only. They do not establish runtime behavior of real global hooks, cursor handoff, IME, clipboard, DPI handling or Android device interaction; those remain P3 acceptance work.

## Evidence boundaries

| Check | Where it runs | What it establishes |
| --- | --- | --- |
| Core regression tests | Mac or Windows | Packet bytes/parser, fake ADB, fake transport, timeouts and cleanup |
| Solution cross-build | Mac | Core, WPF host and Windows tests compile |
| Windows adapter tests | Windows CI | Native struct layouts, pure mapping/geometry, queue and WPF composer event logic (26 passed in the linked run) |
| Packaged artifact | Windows CI | Self-contained x64 package produced and uploaded in the linked run; device and interactive behavior remain unverified |
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
- [ ] Select A→B and A→B→A while connecting and while remote. Only the final selected phone receives input; an offline selection does not fall back to another phone. Reconnect the selected phone, cancel a pending Wi-Fi operation with a newer selection, and confirm manual disconnect stays disconnected. Include paired mDNS endpoints.
- [ ] Enter and return across all four edges; click, drag, wheel, horizontal scroll and right-click Back/secondary mode. No input leaks into a PC application while remote.
- [ ] Secondary monitor left/right/portrait, negative coordinates, 100/150/200% DPI, primary-monitor changes and unplugging a monitor. Internal edges do not enter Android.
- [ ] Ctrl+C/V/A, arrows/Home/End, function keys, key repeat and modifiers held across handoff. No stuck key/button after return.
- [ ] Verify Alt+H/B/R/L, Alt+Up/Down, and hold Alt+Tab to switch across several apps; release Alt before Tab as well as after Tab. Verify the Windows task switcher remains available while local and no modifier remains stuck after disconnect or emergency return.
- [ ] Without an existing ADB installation, select a Google Platform Tools Windows ZIP in Settings; confirm signature validation, USB authorization, connection and preservation of any shared ADB server. Reject modified, unsigned, malformed and incompatible ZIP files.
- [ ] Check for updates manually with network available and unavailable; verify only stable Windows releases are offered.
- [ ] Microsoft Vietnamese Telex in Samsung Notes and browser input: words, editing accents, Backspace, punctuation, Enter, shortcuts, switching layout, pointer movement and focus loss.
- [ ] UniKey **Unicode Telex**, then **Unicode VNI**, in both input targets: the same cases; no duplicate characters or keystrokes landing in a PC application.
- [ ] Composed mode: pending word followed by mouse movement; committed words followed by pending text and immediate emergency return; rapid exit/re-entry preserves ordering.
- [ ] Clipboard both directions, Unicode/empty text, unchanged clipboard, sharing disabled, non-text local clipboard and a temporarily busy clipboard. No automatic image/file replacement on Windows.
- [ ] Emergency shortcut, quit, cable removal, server exit, transport stall, lock/unlock, UAC, sleep/wake and focus loss all restore local control.
- [ ] Return local while entry is still pending, then immediately re-enter; no late capture or stale input reaches Android. Quit during disconnect or a stalled ADB command; input is local immediately and teardown finishes without hanging.
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
