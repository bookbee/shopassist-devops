# Brings up the whole ShopAssist platform: Postgres, Ollama (+ model pull),
# the FastAPI backend, and the storefront client - in dependency
# order.
#
# Usage:
#   .\scripts\up.ps1               # bundled Ollama container (default)
#   .\scripts\up.ps1 -Docker       # LLM in the bundled Ollama container
#   .\scripts\up.ps1 -Local        # LLM from an Ollama on this machine
#   .\scripts\up.ps1 -Lms          # LLM from LM Studio
#
# With no switch the mode comes from SHOPASSIST_LLM_MODE in .env
# (lms | local | docker), defaulting to "docker".
#
# -NativeLlm is much faster where the host has a GPU the container can't
# reach. Needs both models pulled locally first:
#   ollama pull llama3.2:3b ; ollama pull nomic-embed-text
# All three modes are served by the single docker-compose.yml.
param([switch]$Docker, [switch]$Local, [switch]$Lms)
$ErrorActionPreference = "Stop"

$ComposeArgs = @("-f", "docker-compose.yml")
if (@($Docker, $Local, $Lms | Where-Object { $_ }).Count -gt 1) {
    Write-Host "Error: pick at most one of -Docker, -Local, -Lms." -ForegroundColor Red; exit 1
}
$ModeFromFlag = if ($Docker) { "docker" } elseif ($Local) { "local" } elseif ($Lms) { "lms" } else { "" }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ParentDir = Split-Path -Parent $RootDir

$AllProjects = @("shopassist-database", "shopassist-model", "shopassist-service", "shopassist-client")
# No .env bootstrapping for the sibling projects, deliberately. Every
# setting the platform needs is either defaulted in a compose file
# (${VAR:-default}) or pinned explicitly in this repo's
# docker-compose.yml, so the stack starts correctly with no .env anywhere.
#
# It used to copy each project's .env.example into place, which was worse
# than useless: Compose resolves an include:d file's ${VAR} against THAT
# file's own directory .env, so those copies silently changed how the
# platform ran, differently on every machine. Sibling .env files are for
# running that project standalone - see the README's Configuration section.

# Compose reads shopassist-devops\.env on its own, but this script does not -
# so a variable set ONLY there was invisible to the preflight checks below.
# Shell environment wins over the file, the same precedence Compose applies.
function Import-EnvValue([string]$Key) {
    $file = Join-Path $RootDir ".env"
    if (-not (Test-Path $file)) { return }
    if ([Environment]::GetEnvironmentVariable($Key)) { return }
    $line = Select-String -Path $file -Pattern "^\s*$Key=" | Select-Object -Last 1
    if (-not $line) { return }
    $val = ($line.Line -split '=', 2)[1].Trim().Trim('"').Trim("'")
    [Environment]::SetEnvironmentVariable($Key, $val)
}

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

# After the file exists, before any preflight reads these.
foreach ($k in @("SHOPASSIST_LLM_MODE","LMSTUDIO_MODEL","LMSTUDIO_PORT","LMSTUDIO_EMBEDDING_MODEL","SHOPASSIST_MODEL")) {
    Import-EnvValue $k
}

$LlmMode = if ($ModeFromFlag) { $ModeFromFlag }
           elseif ($env:SHOPASSIST_LLM_MODE) { $env:SHOPASSIST_LLM_MODE } else { "docker" }
# Every mode is environment values plus, where the bundled Ollama isn't
# wanted, --scale ollama=0. One compose file serves all three; api's
# depends_on on ollama-bootstrap is `required: false` so a scaled-to-zero
# Ollama is skipped rather than blocking startup.
$ScaleArgs = @()
$LmsPort = if ($env:LMSTUDIO_PORT) { $env:LMSTUDIO_PORT } else { "1234" }
switch ($LlmMode) {
    "docker" { }
    "local"  {
        $env:OLLAMA_API_BASE_URL = "http://host.docker.internal:11434"
        $env:EMBEDDING_API_BASE_URL = $env:OLLAMA_API_BASE_URL
        $ScaleArgs = @("--scale","ollama=0","--scale","ollama-bootstrap=0")
    }
    "lms"    {
        $env:OLLAMA_API_BASE_URL = "http://host.docker.internal:$LmsPort"
        # Embeddings default to the bundled Ollama container, and must be set
        # EXPLICITLY: docker-compose.yml defaults EMBEDDING_API_BASE_URL to
        # ${OLLAMA_API_BASE_URL:-...}, which the line above just repointed at
        # LM Studio - so leaving it unset asked LM Studio for
        # "nomic-embed-text", a name only Ollama uses. That 404'd every
        # embedding: 0 documents indexed and every policy question answered
        # from nothing, while chat looked perfectly fine. The
        # LMSTUDIO_EMBEDDING_MODEL branch below overrides this.
        $env:EMBEDDING_API_BASE_URL = "http://ollama:11434"
        # LM Studio rejects response_format={"type":"json_object"}; it wants a
        # JSON schema, which is what the OpenAI SDK's .parse() sends.
        $env:LOCAL_STRUCTURED_MODE = "parse"
        # SHOPASSIST_MODEL is what every OLLAMA_<ROLE>_MODEL defaults to, so
        # setting it here covers all five chat roles at once.
        $env:SHOPASSIST_MODEL = $env:LMSTUDIO_MODEL
    }
    default  {
        Write-Host "Error: unknown LLM mode '$LlmMode' (expected lms, local or docker)." -ForegroundColor Red
        exit 1
    }
}
Write-Host "==> LLM mode: $LlmMode"
$NativeLlm = ($LlmMode -eq "local"); $LmStudio = ($LlmMode -eq "lms")

# No `docker volume create` step: shopassist-postgres-data used to be
# declared `external: true` in shopassist-database's compose file, which
# meant it had to exist before the very first `docker compose up`. It's
# Compose-managed now (still with a fixed, unprefixed name, so standalone
# and platform runs share one database), so `docker compose up -d` alone is
# enough - this script is a convenience, not a prerequisite.

if ($NativeLlm) {
    Write-Host "==> Using the Ollama on this machine (bundled container will not start) ..."
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5
    } catch {
        Write-Host "Error: no Ollama answering on http://localhost:11434 - start it, or use -Docker." -ForegroundColor Red
        exit 1
    }
    $have = $tags.models | ForEach-Object { $_.name }
    $want = @($(if ($env:SHOPASSIST_MODEL) { $env:SHOPASSIST_MODEL } else { "llama3.2:3b" }), "nomic-embed-text")
    $missing = $want | Where-Object { $m = $_; -not ($have | Where-Object { $_ -like "$($m.Split(':')[0])*" }) }
    if ($missing) {
        Write-Host "Error: your native Ollama is missing: $($missing -join ', ')" -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "         ollama pull $m" -ForegroundColor Red }
        exit 1
    }
    Write-Host "    native Ollama OK (chat + embedding models present)"
}

if ($LmStudio) {
    $port = if ($env:LMSTUDIO_PORT) { $env:LMSTUDIO_PORT } else { "1234" }
    Write-Host "==> Using LM Studio on localhost:$port for the chat roles ..."
    try { $m = Invoke-RestMethod -Uri "http://localhost:$port/v1/models" -TimeoutSec 5 }
    catch {
        Write-Host "Error: nothing answering on http://localhost:$port/v1/models" -ForegroundColor Red
        Write-Host "       In LM Studio: load your model, then Developer tab -> Start Server." -ForegroundColor Red
        exit 1
    }
    $ids = $m.data | ForEach-Object { $_.id }
    if (-not $env:LMSTUDIO_MODEL) {
        Write-Host "Error: set `$env:LMSTUDIO_MODEL to one of:" -ForegroundColor Red
        $ids | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
        exit 1
    }
    if ($ids -notcontains $env:LMSTUDIO_MODEL) {
        Write-Host "Error: LM Studio is not serving '$($env:LMSTUDIO_MODEL)'. It has:" -ForegroundColor Red
        $ids | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "    LM Studio OK (serving '$($env:LMSTUDIO_MODEL)')"

    # Optional: embeddings on LM Studio too. Checked hard, because the failure
    # mode is silent - a wrong dimension doesn't error, it just makes every
    # RAG lookup meaningless and poisons the stored vectors.
    if ($env:LMSTUDIO_EMBEDDING_MODEL) {
        if ($ids -notcontains $env:LMSTUDIO_EMBEDDING_MODEL) {
            Write-Host "Error: LM Studio is not serving embedding model '$($env:LMSTUDIO_EMBEDDING_MODEL)'. It has:" -ForegroundColor Red
            $ids | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
            exit 1
        }
        $dims = $null
        try {
            $body = @{ model = $env:LMSTUDIO_EMBEDDING_MODEL; input = "dimension probe" } | ConvertTo-Json
            $probe = Invoke-RestMethod -Uri "http://localhost:$port/v1/embeddings" -Method Post `
                        -ContentType "application/json" -Body $body -TimeoutSec 60
            $dims = $probe.data[0].embedding.Count
        } catch { }
        if ($dims -ne 768) {
            $got = if ($dims) { $dims } else { "no" }
            Write-Host "Error: '$($env:LMSTUDIO_EMBEDDING_MODEL)' returned $got dimensions, but this project needs exactly 768." -ForegroundColor Red
            Write-Host "       768 is fixed by services/rag.py's FAISS index and shopassist-database's VECTOR(768)" -ForegroundColor Red
            Write-Host "       column. Load a 768-dim model (e.g. nomic-embed-text-v1.5), or unset" -ForegroundColor Red
            Write-Host "       LMSTUDIO_EMBEDDING_MODEL to keep embeddings on the bundled Ollama." -ForegroundColor Red
            exit 1
        }
        $env:EMBEDDING_API_BASE_URL = "http://host.docker.internal:$port"
        $env:EMBEDDING_MODEL = $env:LMSTUDIO_EMBEDDING_MODEL
        $ScaleArgs = @("--scale","ollama=0","--scale","ollama-bootstrap=0")
        Write-Host "    embeddings also on LM Studio ('$($env:LMSTUDIO_EMBEDDING_MODEL)', 768 dims verified)"
        Write-Host "    the bundled Ollama container will NOT be started - nothing needs it"
    } else {
        Write-Host "    embeddings stay on the bundled Ollama (set LMSTUDIO_EMBEDDING_MODEL to change)"
    }
}

Write-Host "==> Starting the platform (first run pulls/builds images and downloads an LLM - can take several minutes) ..."
Set-Location $RootDir
docker compose @ComposeArgs up -d --build @ScaleArgs

Write-Host ""
Write-Host "==> Current status:"
docker compose @ComposeArgs ps

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
