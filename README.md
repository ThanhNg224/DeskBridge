# DeskBridge for Windows (experimental)

DeskBridge for Windows is an experimental Windows 11 x64 host, built independently with C#/.NET 10 and WPF. It uses the same Java Android server and protocol as the macOS app. The Windows CI build and automated checks pass; interactive Windows and physical-device acceptance are still pending.

The default `main` branch contains the stable macOS ARM64 app. See the [macOS README](https://github.com/ThanhNg224/DeskBridge/tree/main) for that version. This `windows` branch is the source for Windows development. See the [Windows guide](windows/README.md), [acceptance record](docs/WINDOWS_ACCEPTANCE.md), and GitHub milestones for [P1](https://github.com/ThanhNg224/DeskBridge/milestone/1), [P2](https://github.com/ThanhNg224/DeskBridge/milestone/2), and [P3](https://github.com/ThanhNg224/DeskBridge/milestone/3).

## Requirements

- Windows 11 x64.
- Android 13 or newer with USB debugging enabled.
- Android SDK Platform Tools (`adb.exe`) available on `PATH` or selected in DeskBridge Settings.

## Download and run

Download the [Windows x64 CI ZIP artifact](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284/artifacts/12035440464) from the [successful workflow run](https://github.com/ThanhNg224/DeskBridge/actions/runs/38875077284). A GitHub release is not yet available for Windows.

Download the complete ZIP artifact and extract all its contents to a writable folder. Keep the included server JAR beside `DeskBridge.Windows.exe`, then run the executable. Authorize USB debugging on the phone when prompted. Press **Ctrl+Alt+Shift+Esc** to return control to Windows immediately.

See the [Windows guide](windows/README.md) for detailed usage and development instructions, and the [acceptance record](docs/WINDOWS_ACCEPTANCE.md) for current verification status.
