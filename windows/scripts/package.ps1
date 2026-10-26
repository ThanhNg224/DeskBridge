param(
    [Parameter(Mandatory = $true)][string]$ServerJar,
    [switch]$RequireInstaller
)
$ErrorActionPreference = 'Stop'
$ServerJar = (Resolve-Path $ServerJar).Path
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $root
try {
    $out = Join-Path $root 'build/package'
    if (Test-Path $out) { Remove-Item -Recurse -Force $out }
    dotnet publish src/DeskBridge.Windows/DeskBridge.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -p:PublishSingleFile=false -p:PublishReadyToRun=true -p:RestoreLockedMode=true -o $out
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
    Write-Output "Created portable ZIP: $zip"

    # Search for Inno Setup Compiler (ISCC)
    $iscc = (Get-Command iscc -ErrorAction SilentlyContinue)?.Source
    if (-not $iscc) {
        $candidates = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:ProgramFiles} 'Inno Setup 6\ISCC.exe'),
            (Join-Path ${env:LOCALAPPDATA} 'Programs\Inno Setup 6\ISCC.exe')
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) { $iscc = $c; break }
        }
    }

    $version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
    $issFile = Join-Path $root 'installer/DeskBridge.iss'

    if ($iscc) {
        Write-Output "Building installer with Inno Setup ($iscc)..."
        & $iscc "/DMyAppVersion=$version" "/DSourceDir=$out" "/DOutputDir=$(Join-Path $root 'build')" $issFile
        if ($LASTEXITCODE) { throw 'Inno Setup compilation failed.' }
        $setupExe = Join-Path $root 'build/DeskBridge-Setup-x64.exe'
        if (-not (Test-Path $setupExe)) { throw 'Installer output file not found.' }
        Write-Output "Created installer: $setupExe"
    } elseif ($RequireInstaller) {
        throw 'Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6 or add it to PATH.'
    } else {
        Write-Warning 'Inno Setup (ISCC.exe) not found; skipping installer creation. Only portable ZIP was built.'
    }
} finally { Pop-Location }
