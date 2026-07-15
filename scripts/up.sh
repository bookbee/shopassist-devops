#!/usr/bin/env bash
# Brings up the whole ShopAssist platform: Postgres, Ollama (+ model pull),
# the FastAPI backend, and the storefront client — in dependency
# order.
#
# Usage: ./scripts/up.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"

ALL_PROJECTS=(shopassist-database shopassist-model shopassist shopassist-client)
# All four are `include:`d as-is (each owns its own docker-compose.yml) and
# reads its own .env for compose variable substitution. shopassist-database
# and shopassist-model ship an .env.example to bootstrap from — shopassist
# (the API) and shopassist-client (the storefront) both hardcode their
# container-relevant defaults directly in their own docker-compose.yml, so
# neither needs one for this to work.
ENV_BOOTSTRAP_PROJECTS=(shopassist-database shopassist-model)

echo "==> Checking sibling checkouts in $PARENT_DIR ..."
missing=0
for proj in "${ALL_PROJECTS[@]}"; do
    if [ ! -d "$PARENT_DIR/$proj" ]; then
        echo "    missing: $proj" >&2
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo "Error: clone the missing project(s) above as siblings of shopassist-devops, then re-run this script." >&2
    exit 1
fi

echo "==> Checking Docker is installed and running ..."
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker CLI not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon isn't running. Start Docker Desktop and try again." >&2
    exit 1
fi

echo "==> Ensuring shopassist-devops/.env exists ..."
if [ ! -f "$ROOT_DIR/.env" ] && [ -f "$ROOT_DIR/.env.example" ]; then
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
    echo "    created shopassist-devops/.env from .env.example"
fi

echo "==> Ensuring each included project has its own .env ..."
for proj in "${ENV_BOOTSTRAP_PROJECTS[@]}"; do
    proj_dir="$PARENT_DIR/$proj"
    if [ ! -f "$proj_dir/.env" ] && [ -f "$proj_dir/.env.example" ]; then
        cp "$proj_dir/.env.example" "$proj_dir/.env"
        echo "    created $proj/.env from .env.example"
    fi
done

echo "==> Ensuring the external Postgres volume exists ..."
docker volume create shopassist-postgres-data >/dev/null

echo "==> Starting the platform (first run pulls/builds images and downloads an LLM — can take several minutes) ..."
cd "$ROOT_DIR"
docker compose up -d --build

echo
echo "==> Current status:"
docker compose ps

cat <<'EOF'

Still coming up? Useful commands:

    docker compose logs -f model-bootstrap   # watch the model download
    docker compose ps                        # health status of every service

Once shopassist-client shows "healthy":

    Storefront:  http://localhost:8501
    API docs:    http://localhost:8000/docs
    Ollama:      http://localhost:11434

Stop everything with ./scripts/down.sh
EOF
