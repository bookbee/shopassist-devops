#!/usr/bin/env bash
# Stops the platform. Data (Postgres volume, downloaded Ollama models) is
# preserved by default — pass --wipe to also delete it.
#
# Usage: ./scripts/down.sh [--wipe]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

if [ "${1:-}" = "--wipe" ]; then
    echo "==> Stopping the platform and deleting all data (Postgres + Ollama models) ..."
    docker compose down -v
    docker volume rm shopassist-postgres-data 2>/dev/null || true
    echo "Wiped. Next ./scripts/up.sh starts from a clean slate (including re-downloading the model)."
else
    echo "==> Stopping the platform (data preserved) ..."
    docker compose down
    echo "Data preserved. Run './scripts/down.sh --wipe' instead to delete it, or './scripts/up.sh' to start again."
fi
