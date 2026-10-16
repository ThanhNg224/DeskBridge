param([Parameter(Mandatory = $true)][string]$ServerJar)
$ErrorActionPreference = 'Stop'
$ServerJar = (Resolve-Path $ServerJar).Path
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    $out = Join-Path $root 'build/package'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    dotnet publish src/DeskBridge.Windows/DeskBridge.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -p:PublishSingleFile=false -p:RestoreLockedMode=true -o $out
    if ($LASTEXITCODE) { throw 'Publish failed.' }
    Copy-Item $ServerJar (Join-Path $out 'deskbridge-server.jar')
    Copy-Item VERSION (Join-Path $out 'VERSION')
    Copy-Item README.md (Join-Path $out 'README.md')
    $source = git rev-parse HEAD
    if ($LASTEXITCODE) { throw 'Cannot identify source commit.' }
    Set-Content -Path (Join-Path $out 'SOURCE_COMMIT') -Value $source
    Get-FileHash $ServerJar -Algorithm SHA256 | Select-Object Hash | ConvertTo-Json | Set-Content (Join-Path $out 'SERVER_SHA256.json')
    $zip = Join-Path $root 'build/DeskBridge-windows-x64.zip'
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip
    Write-Output $zip
} finally { Pop-Location }
