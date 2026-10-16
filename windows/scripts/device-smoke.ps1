param([Parameter(Mandatory = $true)][string]$Serial,
      [string]$App = "$PSScriptRoot/../build/package/DeskBridge.Windows.exe",
      [string]$Report = "$PSScriptRoot/../build/device-smoke.json")
$ErrorActionPreference = 'Stop'
if ($env:DESKBRIDGE_DEVICE -ne '1') { throw 'Set DESKBRIDGE_DEVICE=1 to opt in. The smoke test moves the phone pointer.' }
$appPath = (Resolve-Path $App).Path
$reportPath = [IO.Path]::GetFullPath($Report)
# A report is created only on success; discard any previous result before the run.
if (Test-Path $reportPath) { Remove-Item $reportPath }
$process = Start-Process -FilePath $appPath -ArgumentList @('--device-smoke', "`"$reportPath`"", '--serial', "`"$Serial`"") -PassThru -Wait
if ($process.ExitCode -ne 0 -or !(Test-Path $reportPath)) { throw 'Device smoke failed; inspect the application error.' }
Get-Content $reportPath
