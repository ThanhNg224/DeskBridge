# DeskBridge project rules

## Platforms and scope

- DeskBridge has independent native hosts: macOS ARM64 Swift on `main` and Windows 11 x64 C#/.NET/WPF on `windows`.
- Both hosts use the shared plain-Java Android server and protocol. `mac/` on `windows` is an inherited reference snapshot; supported Mac development belongs on `main`.
- New features default to both hosts: design shared behavior together, with slight implementation and testing priority for Mac because the user uses Mac.
- Before designing or implementing a new feature, ask with interactive choices: **Both (Mac first)** (recommended), **macOS only**, or **Windows only**, unless the user has already explicitly chosen the scope.
- Existing platform branches are authoritative. Port shared server/protocol fixes selectively; never merge the whole `windows` branch into `main`.

## Project references and checks

- References: current branch `README.md` for commands; `docs/ARCHITECTURE.md` for protocol/decisions. On `windows`, use `windows/README.md` and `docs/WINDOWS_ACCEPTANCE.md` for Windows checks/acceptance.
- Mac checks: `scripts/check.sh`.
- Run Windows .NET commands from `windows/` to use its `global.json`.
- Portable tests: `dotnet test tests/DeskBridge.Core.Tests -c Release`.
- Cross-build: `dotnet build DeskBridge.slnx -c Release --warnaserror`.
- Windows-native checks: `scripts/check.ps1` and `scripts/package.ps1`; see `windows/README.md` for arguments.
- Mac/core/CI evidence differs from actual Windows plus Android acceptance. Do not describe Windows runtime behavior as passed without the physical acceptance gate.

## Cross-platform gotchas

- Protocol v1 is a byte contract: `DOWN=0`, `UP=1`. Shared changes need tests on both hosts.
- The Android server uses an abstract Unix socket with a random name and token. Clean up only this session's forward and process; never kill the shared ADB server.
- Keep the selected device pinned while offline. Late ADB results must not revive an old session. Restore local control before awaiting teardown.
- Handoff uses exposed left/right edges of each display; top/bottom only on the primary display. Use relative mouse deltas while parked.
- Text composition requires a real focused native editor. Raw printable keys and text input must not duplicate. For WPF `TextBox`, observe handled `TextInput`.
- On Mac, preserve `CursorShield` focus/warp order and the development signing identity; Dock hiding and Accessibility grants depend on it.
- Android `CursorOverlay` needs a 1 px offset to avoid click occlusion. Unicode `TEXT` uses the existing paste path.
