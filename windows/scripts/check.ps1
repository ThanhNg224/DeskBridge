$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    dotnet restore DeskBridge.slnx --locked-mode
    if ($LASTEXITCODE) { throw 'Locked restore failed.' }
    dotnet build DeskBridge.slnx --no-restore -c Release --warnaserror
    if ($LASTEXITCODE) { throw 'Build failed.' }
    dotnet test DeskBridge.slnx --no-build --no-restore -c Release --logger 'trx;LogFilePrefix=windows' --results-directory TestResults
    if ($LASTEXITCODE) { throw 'Tests failed.' }
} finally { Pop-Location }
