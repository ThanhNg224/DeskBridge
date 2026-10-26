# DeskBridge Windows

This permanent `windows` branch develops the independent Windows 11 x64 host. The permanent `main` branch is the source of truth for the completed macOS ARM64 app. Keep Windows work on `windows`; never merge this whole branch into `main`. Port shared server/protocol fixes selectively and verify both hosts when their contract changes.

## Layout and scope

- `windows/src/DeskBridge.Core`: portable .NET 10 protocol, ADB and session logic.
- `windows/src/DeskBridge.Windows`: WPF UI and Win32 adapters.
- `windows/tests`: portable core and Windows-only adapter/composer tests.
- `server`: plain Java Android server, no APK, Gradle, Kotlin or dependencies.
- `mac`: inherited reference snapshot; supported Mac development is on `main`.

Read `windows/README.md` and `docs/WINDOWS_ACCEPTANCE.md` for current progress, commands and evidence boundaries. `docs/ARCHITECTURE.md` records the shared protocol and original Mac design.

## Verification

Run .NET commands from `windows/` so `global.json` pins SDK 10.0.401. Keep logs in temporary files and print filtered summaries.

On macOS:

```sh
scripts/test_server.sh
scripts/build_server.sh
cd windows
dotnet restore DeskBridge.slnx --locked-mode
dotnet test tests/DeskBridge.Core.Tests -c Release --no-restore
dotnet build DeskBridge.slnx -c Release --no-restore --warnaserror
```

On Windows, from `windows/`:

```powershell
./scripts/check.ps1
./scripts/package.ps1 -ServerJar ../server/build/deskbridge-server.jar
```

The JAR is built on Mac/Linux or downloaded from the same-commit CI server job. Native adapter/composer tests run on Windows CI; actual hooks, IME/UniKey, cursor handoff, DPI and device behavior require the phase 3 physical matrix. Cross-builds and ping measurements do not prove that behavior.

`--diagnostics REPORT.json` exports inspectable state. Device smoke requires `DESKBRIDGE_DEVICE=1` and an explicit serial; it moves the phone pointer. Do not run it without a device-testing request.

## Contract and safety

- Match protocol v1 bytes with `PacketType.java`/`ProtocolDecoder.java` and the protocol table. DOWN=0, UP=1. Keep regression tests aligned on both branches for a shared change.
- The server listens only on a random Android abstract Unix socket. ADB forwards a local port; each session authenticates with its random token. Never log tokens, input text or clipboard contents.
- Launch ADB through argument arrays. Remove only the current session's forward/process; do not kill the shared ADB daemon.
- Keep hook callbacks cheap and off the UI thread. No network, file I/O or waits in a hook callback.
- Return local control before slow teardown. The emergency chord is Ctrl+Alt+Shift+Esc. Release clipping, hide the control shield and prevent stale queued input from crossing visits.
- Composed input must reach a verified focused native text control. Observe handled TextInput events; TextBox handles them before normal instance handlers. Microsoft Telex and UniKey Unicode Telex/VNI still require physical acceptance.
- Wi-Fi TCP/IP ADB is unencrypted; pairing is performed outside the app. Preserve the server's existing transport/security boundaries.

## Delivery

Windows CI runs on push/PR to `windows`; Mac CI remains associated with `main`. Track phase 1/2/3 in GitHub milestones 1/2/3 and issues 1–14. Keep physical acceptance issues labeled `blocked:windows-device` until tested.

Windows uses its own `windows/VERSION`, eventual `windows-vX.Y.Z` prerelease tags, `DeskBridge-windows-x64.zip` and `DeskBridge-Setup-x64.exe`. Keep Mac tags/assets unchanged. Commit/push only when requested; a build/package does not authorize a merge or public release.
