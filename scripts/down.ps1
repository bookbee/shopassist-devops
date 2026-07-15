# Stops the platform. Data (Postgres volume, downloaded Ollama models) is
# preserved by default - pass -Wipe to also delete it.
#
# Usage: .\scripts\down.ps1 [-Wipe]
param(
    [switch]$Wipe
)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
Set-Location $RootDir

if ($Wipe) {
    Write-Host "==> Stopping the platform and deleting all data (Postgres + Ollama models) ..."
    docker compose down -v
    docker volume rm shopassist-postgres-data 2>$null
    Write-Host "Wiped. Next .\scripts\up.ps1 starts from a clean slate (including re-downloading the model)."
} else {
    Write-Host "==> Stopping the platform (data preserved) ..."
    docker compose down
    Write-Host "Data preserved. Run '.\scripts\down.ps1 -Wipe' instead to delete it, or '.\scripts\up.ps1' to start again."
}
