# DeskBridge for Windows (experimental)

Independent Windows 11 x64 host, built with C#/.NET 10 and WPF. The macOS ARM64 application remains in `mac/`. Both hosts speak the same protocol to the Java server in `server/`.

**Automated Windows CI and packaging have passed; interactive Windows and physical-device acceptance are pending.** CI ran the Windows-native automated tests and produced a self-contained x64 package. These checks do not establish that real global hooks, cursor hiding, mixed-DPI displays, Microsoft IME or UniKey work correctly on a user's PC. Follow the [acceptance checklist](../docs/WINDOWS_ACCEPTANCE.md) before treating this build as supported.

## Run a packaged build

1. Use Windows 11 x64 and an Android 13+ phone with USB debugging enabled.
2. Install Android SDK Platform Tools. Put `adb.exe` on PATH, or choose it in DeskBridge Settings. No JDK, Android SDK or .NET installation is required to run the self-contained package.
3. Choose your distribution:
   - **Installer (`DeskBridge-Setup-x64.exe`)**: Recommended for end users. Installs per-user without requiring administrator privileges, creates Start Menu/Desktop shortcuts, and registers an uninstaller in Windows Settings.
   - **Portable (`DeskBridge-windows-x64.zip`)**: Extract the whole ZIP into a writable folder. Keep `deskbridge-server.jar` beside `DeskBridge.Windows.exe` and run the executable directly.
   The build is unsigned at this stage; Windows SmartScreen warnings need to be acknowledged during preview testing. Do not disable Windows security globally.
4. Authorize the PC on the phone, select the device and enable DeskBridge. If exactly one phone is ready, it is selected automatically. Changes in Settings take effect with **Apply & reconnect**.
5. Push through the selected screen edge. Press **Ctrl+Alt+Shift+Esc** to return control immediately. Closing the Settings window leaves the app in the tray; choose **Quit** to stop it.

Run as a normal user. UAC, sign-in/lock screens and other secure desktops are not remote-control targets. DeskBridge returns control locally when it detects that boundary.

Changing the selected device stops the previous session before starting the new one. If that device disappears, DeskBridge keeps the selection and waits for it; it does not switch to another phone. **Disconnect** pauses automatic reconnect until you choose a device, connect explicitly or apply settings. ADB commands have an 8-second deadline; cancelling one waits up to 5 seconds for its local process to exit.

### Text input and clipboard

**Direct keys** is the default: Windows key events become Android key events, with Ctrl+C/V/A retaining their usual role. **Composed text** focuses a small native text preview so Microsoft Vietnamese Telex or UniKey can edit the word locally. Space or punctuation commits the text; a pointer action flushes an uncommitted word before movement. Escape cancels an uncommitted word. An unfinished IME composition is cancelled on forced exit.

Microsoft Telex and UniKey Unicode Telex/VNI are implementation targets, **not verified compatibility claims**. Focus, injected-key ordering and composition behavior require phase 3 testing. Other layouts, IMEs, clipboard managers and elevated applications are not yet verified.

Clipboard sharing is text only and happens at visit boundaries. It can be disabled. Accented text uses the Android server's existing clipboard-paste path, which temporarily changes the phone clipboard and may show a phone clipboard notification. Clipboard images/files are outside this feature.

### Wi-Fi

**Switch to Wi-Fi** requires an authorized USB device and enables legacy ADB TCP/IP. This traffic is not encrypted; use a trusted network. For paired Wireless Debugging, perform pairing outside DeskBridge, then enter the phone's IPv4 address and **connection** port. The pairing port can differ. Disconnect Wi-Fi removes only the selected ADB endpoint; it does not turn off network debugging on the phone.

## Development from macOS

Install the .NET SDK pinned in `global.json` (10.0.401), alongside the existing Java/Android tools. From the repository root:

```sh
scripts/test_server.sh
scripts/build_server.sh
cd windows
dotnet restore DeskBridge.slnx --locked-mode
dotnet test tests/DeskBridge.Core.Tests -c Release --no-restore
dotnet build DeskBridge.slnx -c Release --no-restore --warnaserror
```

The core tests run on macOS. The Windows tests reference WPF and **run only on Windows**; cross-building them checks compilation, not native behavior. Local app runs can use `DESKBRIDGE_SERVER_JAR` to select a built server JAR. There is no simulated WPF runtime on Mac.

## Windows checks and package

In PowerShell, from `windows/`:

```powershell
./scripts/check.ps1
./scripts/package.ps1 -ServerJar ../server/build/deskbridge-server.jar
```

The server JAR is built on macOS/Linux. Windows CI downloads the artifact produced by its Ubuntu job at the same commit, runs automated tests, then packages both `build/DeskBridge-windows-x64.zip` (portable) and `build/DeskBridge-Setup-x64.exe` (Inno Setup installer). There is no CI device test. The package includes `VERSION`, `SOURCE_COMMIT` and the server SHA-256 alongside the self-contained ReadyToRun app. CI artifacts are test builds, not GitHub releases.

```powershell
# Exports OS, process architecture, ADB/device and physical-display information.
./build/package/DeskBridge.Windows.exe --diagnostics "$PWD/build/diagnostics.json"

# Opt-in: opens a real Android session and moves the phone pointer; no click/key/clipboard change.
$env:DESKBRIDGE_DEVICE = '1'
./scripts/device-smoke.ps1 -Serial 'YOUR_ADB_SERIAL'
```

Device smoke checks handshake, enter/move/leave and a local heartbeat interval. It does not measure end-to-end latency or validate hooks/IME/clipboard. Session logs are in `%LOCALAPPDATA%\DeskBridge\session.log`, settings in `settings.json`. Logs contain operation names, timestamps and exception types, not input, clipboard text or session tokens. Diagnostic reports contain device identifiers and should be reviewed before sharing.

## Progress and GitHub tracking

The repository keeps permanent platform branches: `main` is the source of truth for the macOS ARM64 app, and `windows` is the source of truth for the Windows 11 x64 host. Develop Windows work on `windows` and push it there. Do not merge the whole Windows branch into `main`. Port shared server or protocol fixes selectively between branches and test them on both branches. Keep platform versions and tags independent (`vX.Y.Z` for Mac and `windows-vX.Y.Z` for Windows). The inherited `mac/` snapshot on `windows` is not the supported Mac source; use `main` for Mac changes.

| Milestone | Progress | GitHub tracking |
| --- | --- | --- |
| [P1: Foundation](https://github.com/ThanhNg224/DeskBridge/milestone/1) | Foundation and package pipeline verified by successful Windows CI. | Issues #1–#3 |
| [P2: Implementation & Automated Tests](https://github.com/ThanhNg224/DeskBridge/milestone/2) | Automated checks pass: 43 core tests, 26 Windows adapter/composer tests, 32 Java server tests; Windows Release build has 0 warnings/errors and the self-contained x64 package was produced. | Issues #4–#10 |
| [P3: Windows Acceptance](https://github.com/ThanhNg224/DeskBridge/milestone/3) | Actual Windows and Android acceptance is pending. | Issues #11–#14; label: `blocked:windows-device` |

Remote evidence: [successful CI run](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284) for source [`a20a9081809971013deff97bd818b81f345c3f29`](https://github.com/ThanhNg224/DeskBridge/commit/a20a9081809971013deff97bd818b81f345c3f29), with the [Windows x64 ZIP artifact](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284/artifacts/12035440464). See the [acceptance record](../docs/WINDOWS_ACCEPTANCE.md) for the verified job details and outstanding physical checks.

Use the GitHub labels `platform:windows`, `platform:macos`, `area:shared` and `blocked:windows-device` to identify platform, shared-area and device-blocked work.

## Release boundary

Windows has its own `VERSION` and eventual `windows-v0.1.0-alpha.N` prerelease tags. The Mac version/tag/`DeskBridge.zip` remain unchanged. Packaging does not publish, create tags or upload a release. Release publication requires a separate request. See [the acceptance record](../docs/WINDOWS_ACCEPTANCE.md) for evidence and outstanding checks.
