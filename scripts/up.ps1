# Brings up the whole ShopAssist platform: Postgres, Ollama (+ model pull),
# the FastAPI backend, and the storefront client - in dependency
# order.
#
# Usage: .\scripts\up.ps1
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ParentDir = Split-Path -Parent $RootDir

$AllProjects = @("shopassist-database", "shopassist-model", "shopassist", "shopassist-client")
# All four are `include:`d as-is (each owns its own docker-compose.yml) and
# reads its own .env for compose variable substitution. shopassist-database
# and shopassist-model ship an .env.example to bootstrap from - shopassist
# (the API) and shopassist-client (the storefront) both hardcode their
# container-relevant defaults directly in their own docker-compose.yml, so
# neither needs one for this to work.
$EnvBootstrapProjects = @("shopassist-database", "shopassist-model")

Write-Host "==> Checking sibling checkouts in $ParentDir ..."
$missing = $false
foreach ($proj in $AllProjects) {
    if (-not (Test-Path (Join-Path $ParentDir $proj))) {
        Write-Host "    missing: $proj"
        $missing = $true
    }
}
if ($missing) {
    Write-Host "Error: clone the missing project(s) above as siblings of shopassist-devops, then re-run this script." -ForegroundColor Red
    exit 1
}

Write-Host "==> Checking Docker is installed and running ..."
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "Error: docker CLI not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Red
    exit 1
}
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Docker daemon isn't running. Start Docker Desktop and try again." -ForegroundColor Red
    exit 1
}

Write-Host "==> Ensuring shopassist-devops\.env exists ..."
$rootEnv = Join-Path $RootDir ".env"
$rootEnvExample = Join-Path $RootDir ".env.example"
if (-not (Test-Path $rootEnv) -and (Test-Path $rootEnvExample)) {
    Copy-Item $rootEnvExample $rootEnv
    Write-Host "    created shopassist-devops\.env from .env.example"
}

Write-Host "==> Ensuring each included project has its own .env ..."
foreach ($proj in $EnvBootstrapProjects) {
    $projDir = Join-Path $ParentDir $proj
    $envFile = Join-Path $projDir ".env"
    $envExample = Join-Path $projDir ".env.example"
    if (-not (Test-Path $envFile) -and (Test-Path $envExample)) {
        Copy-Item $envExample $envFile
        Write-Host "    created $proj\.env from .env.example"
    }
}

Write-Host "==> Ensuring the external Postgres volume exists ..."
docker volume create shopassist-postgres-data | Out-Null

Write-Host "==> Starting the platform (first run pulls/builds images and downloads an LLM - can take several minutes) ..."
Set-Location $RootDir
docker compose up -d --build

Write-Host ""
Write-Host "==> Current status:"
docker compose ps

Write-Host @"

Still coming up? Useful commands:

    docker compose logs -f ollama-bootstrap  # watch the model download
    docker compose ps                        # health status of every service

Once shopassist-client shows "healthy":

    Storefront:  http://localhost:8501
    API docs:    http://localhost:8000/docs
    Ollama:      http://localhost:11434

Stop everything with .\scripts\down.ps1
"@
