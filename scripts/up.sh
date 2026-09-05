#!/usr/bin/env bash
# Brings up the whole ShopAssist platform: Postgres, Ollama (+ model pull),
# the FastAPI backend, and the storefront client — in dependency
# order.
#
# Usage:
#   ./scripts/up.sh            # mode from SHOPASSIST_LLM_MODE in .env
#   ./scripts/up.sh --docker   # LLM in the bundled Ollama container
#   ./scripts/up.sh --local    # LLM from an Ollama running on this machine
#   ./scripts/up.sh --lms      # LLM from LM Studio (needs LMSTUDIO_MODEL)
#
# The flag wins for one run; with no flag the mode comes from
# SHOPASSIST_LLM_MODE in shopassist-devops/.env (lms | local | docker),
# defaulting to "docker" - so which model you're running is a property of
# your config, not of whichever command you last typed.
#
# --local is much faster where the host has a GPU the container can't
# reach (Apple Silicon in particular). It needs both models pulled locally
# first: `ollama pull llama3.2:3b && ollama pull nomic-embed-text`.
# All three modes are served by the single docker-compose.yml.
set -euo pipefail

COMPOSE_ARGS=(-f docker-compose.yml)
# Flag only recorded here; the mode can't be resolved until .env is loaded
# (below), since with no flag it comes from SHOPASSIST_LLM_MODE.
MODE_FROM_FLAG=""
case "${1:-}" in
    --docker|--local|--lms) MODE_FROM_FLAG="${1#--}" ;;
    "") ;;
    *) echo "Unknown option: $1 (expected --docker, --local or --lms)" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$ROOT_DIR/.." && pwd)"

ALL_PROJECTS=(shopassist-database shopassist-model shopassist-service shopassist-web)
# No .env bootstrapping for the sibling projects, deliberately. Every
# setting the platform needs is either defaulted in a compose file
# (${VAR:-default}) or pinned explicitly in this repo's
# docker-compose.yml, so the stack starts correctly with no .env anywhere.
#
# It used to copy each project's .env.example into place, which was worse
# than useless: Compose resolves an include:d file's ${VAR} against THAT
# file's own directory .env, so those copies silently changed how the
# platform ran, differently on every machine. Sibling .env files are for
# running that project standalone - see the README's Configuration
# section.

# Compose reads shopassist-devops/.env on its own, but this script does not -
# so a variable set ONLY there was invisible to the preflight checks below,
# and `LMSTUDIO_MODEL=... ` in .env failed with "set LMSTUDIO_MODEL", which
# is about as confusing as an error message gets. Load the handful of keys
# the checks actually need, with the shell environment winning over the
# file - the same precedence Compose itself applies.
load_from_env_file() {
    local key="$1" file="$ROOT_DIR/.env" line val
    [ -f "$file" ] || return 0
    [ -n "${!key:-}" ] && return 0          # already set in the shell: leave it
    line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -1 || true)"
    [ -n "$line" ] || return 0
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"     # strip leading whitespace
    val="${val%"${val##*[![:space:]]}"}"     # strip trailing whitespace
    val="${val%\"}"; val="${val#\"}"          # strip surrounding double quotes
    val="${val%\'}"; val="${val#\'}"          # ...or single quotes
    export "$key=$val"
}

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

# Must happen after the file exists, and before any preflight reads them.
for _k in SHOPASSIST_LLM_MODE LMSTUDIO_MODEL LMSTUDIO_PORT LMSTUDIO_EMBEDDING_MODEL SHOPASSIST_MODEL; do
    load_from_env_file "$_k"
done

# Resolve the mode now that both sources are known: flag > .env > default.
#
# Every mode is just environment values plus, where the bundled Ollama
# isn't wanted, `--scale ollama=0`. There are deliberately NO per-mode
# compose files: docker-compose.yml already exposes every endpoint and
# model as a ${VAR}, and api's depends_on on ollama-bootstrap is
# `required: false`, so a scaled-to-zero Ollama is skipped rather than
# blocking startup. Three overlay files used to encode exactly this.
# Precedence: command-line flag > SHOPASSIST_LLM_MODE in .env > "docker".
# "docker" is the default on purpose: it's the only mode that needs nothing
# installed beyond Docker Desktop, so a clone-and-run on a new machine
# works with no configuration at all. `:-` also catches an empty value, so
# a commented-out or blank SHOPASSIST_LLM_MODE still lands here.
LLM_MODE="${MODE_FROM_FLAG:-${SHOPASSIST_LLM_MODE:-docker}}"
SCALE_ARGS=()
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"

case "$LLM_MODE" in
    docker)
        # docker-compose.yml's defaults already point at the container.
        ;;
    local)
        export OLLAMA_API_BASE_URL="http://host.docker.internal:11434"
        export EMBEDDING_API_BASE_URL="$OLLAMA_API_BASE_URL"
        SCALE_ARGS=(--scale ollama=0 --scale ollama-bootstrap=0)
        ;;
    lms)
        export OLLAMA_API_BASE_URL="http://host.docker.internal:${LMSTUDIO_PORT}"
        # Embeddings default to the bundled Ollama container, and must be
        # set EXPLICITLY: docker-compose.yml defaults
        # EMBEDDING_API_BASE_URL to ${OLLAMA_API_BASE_URL:-...}, which we
        # just pointed at LM Studio - so leaving it unset asked LM Studio
        # for "nomic-embed-text", a name only Ollama uses. That 404'd every
        # embedding: 0 documents indexed, while chat looked fine. The
        # LMSTUDIO_EMBEDDING_MODEL branch below overrides this.
        export EMBEDDING_API_BASE_URL="http://ollama:11434"
        # LM Studio rejects response_format={"type":"json_object"}; it wants
        # a JSON schema, which is what the OpenAI SDK's .parse() sends.
        export LOCAL_STRUCTURED_MODE="parse"
        # SHOPASSIST_MODEL is what every OLLAMA_<ROLE>_MODEL defaults to, so
        # setting it here covers all five chat roles at once.
        export SHOPASSIST_MODEL="${LMSTUDIO_MODEL:-}"
        ;;
    *)
        echo "Error: unknown LLM mode '$LLM_MODE'." >&2
        echo "       Expected lms, local or docker - set SHOPASSIST_LLM_MODE in" >&2
        echo "       shopassist-devops/.env, or pass --lms / --local / --docker." >&2
        echo "       If unsure, use docker - it needs nothing installed but Docker." >&2
        exit 1 ;;
esac
if [ -n "$MODE_FROM_FLAG" ]; then
    echo "==> LLM mode: $LLM_MODE (from the command line)"
else
    echo "==> LLM mode: $LLM_MODE (from SHOPASSIST_LLM_MODE in .env)"
fi

if [ "$LLM_MODE" = "local" ]; then
    echo "==> Using the Ollama on this machine (bundled container will not start) ..."
    if ! curl -sf -m 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo "Error: no Ollama answering on http://localhost:11434 - start it, or use --docker." >&2
        exit 1
    fi
    missing=""
    for model in "${SHOPASSIST_MODEL:-llama3.2:3b}" nomic-embed-text; do
        curl -sf -m 5 http://localhost:11434/api/tags \
            | grep -q "\"${model%%:*}" || missing="$missing $model"
    done
    if [ -n "$missing" ]; then
        echo "Error: your native Ollama is missing:$missing" >&2
        echo "       Pull them first, then re-run:" >&2
        for m in $missing; do echo "         ollama pull $m" >&2; done
        exit 1
    fi
    echo "    native Ollama OK (chat + embedding models present)"
fi

if [ "$LLM_MODE" = "lms" ]; then
    LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
    echo "==> Using LM Studio on localhost:${LMSTUDIO_PORT} for the chat roles ..."
    models_json="$(curl -sf -m 5 "http://localhost:${LMSTUDIO_PORT}/v1/models" || true)"
    if [ -z "$models_json" ]; then
        echo "Error: nothing answering on http://localhost:${LMSTUDIO_PORT}/v1/models" >&2
        echo "       In LM Studio: load your model, then Developer tab -> Start Server." >&2
        echo "       (The server is separate from the chat UI - loading a model is not enough.)" >&2
        exit 1
    fi
    available="$(printf '%s' "$models_json" | sed -n 's/.*\"id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p' | sort -u)"
    if [ -z "${LMSTUDIO_MODEL:-}" ]; then
        echo "Error: set LMSTUDIO_MODEL to one of the ids LM Studio is serving:" >&2
        printf '         %s\n' $available >&2
        echo "       e.g. LMSTUDIO_MODEL=$(printf '%s' "$available" | head -1) ./scripts/up.sh --lms" >&2
        echo "       or set it in shopassist-devops/.env (this script reads that file too)" >&2
        exit 1
    fi
    if ! printf '%s\n' $available | grep -qx "$LMSTUDIO_MODEL"; then
        echo "Error: LM Studio is not serving a model with id '$LMSTUDIO_MODEL'. It has:" >&2
        printf '         %s\n' $available >&2
        echo "       Use the id verbatim - it differs from the display name in the UI." >&2
        exit 1
    fi
    export LMSTUDIO_MODEL LMSTUDIO_PORT
    echo "    LM Studio OK (serving '$LMSTUDIO_MODEL')"

    # Optional: embeddings on LM Studio too. Checked hard, because the
    # failure mode is silent - a wrong dimension doesn't error, it just
    # makes every RAG lookup meaningless and poisons the stored vectors.
    if [ -n "${LMSTUDIO_EMBEDDING_MODEL:-}" ]; then
        if ! printf '%s\n' $available | grep -qx "$LMSTUDIO_EMBEDDING_MODEL"; then
            echo "Error: LM Studio is not serving embedding model '$LMSTUDIO_EMBEDDING_MODEL'. It has:" >&2
            printf '         %s\n' $available >&2
            exit 1
        fi
        dims="$(curl -sf -m 60 "http://localhost:${LMSTUDIO_PORT}/v1/embeddings" \
                 -H 'Content-Type: application/json' \
                 -d "{\"model\":\"${LMSTUDIO_EMBEDDING_MODEL}\",\"input\":\"dimension probe\"}" \
               | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["data"][0]["embedding"]))' 2>/dev/null || true)"
        if [ "$dims" != "768" ]; then
            echo "Error: '$LMSTUDIO_EMBEDDING_MODEL' returned ${dims:-no} dimensions, but this project needs exactly 768." >&2
            echo "       768 is fixed by services/rag.py's FAISS index and shopassist-database's VECTOR(768)" >&2
            echo "       column. Load a 768-dim model (e.g. nomic-embed-text-v1.5), or unset" >&2
            echo "       LMSTUDIO_EMBEDDING_MODEL to keep embeddings on the bundled Ollama." >&2
            exit 1
        fi
        export EMBEDDING_API_BASE_URL="http://host.docker.internal:${LMSTUDIO_PORT}"
        export EMBEDDING_MODEL="$LMSTUDIO_EMBEDDING_MODEL"
        SCALE_ARGS=(--scale ollama=0 --scale ollama-bootstrap=0)
        echo "    embeddings also on LM Studio ('$LMSTUDIO_EMBEDDING_MODEL', 768 dims verified)"
        echo "    the bundled Ollama container will NOT be started - nothing needs it"
    else
        echo "    embeddings stay on the bundled Ollama (set LMSTUDIO_EMBEDDING_MODEL to change)"
    fi
fi

echo "==> Starting the platform (first run pulls/builds images and downloads an LLM — can take several minutes) ..."
cd "$ROOT_DIR"
# ${SCALE_ARGS[@]+"..."} not just "${SCALE_ARGS[@]}": macOS still ships
# bash 3.2, where expanding an EMPTY array under `set -u` aborts with
# "unbound variable" - which is precisely the docker mode, i.e. the
# default path, on the most common developer machine.
docker compose "${COMPOSE_ARGS[@]}" up -d --build ${SCALE_ARGS[@]+"${SCALE_ARGS[@]}"}

echo
echo "==> Current status:"
docker compose "${COMPOSE_ARGS[@]}" ps

cat <<'EOF'

Still coming up? Useful commands:

    docker compose logs -f ollama-bootstrap  # watch the model download
    docker compose ps                        # health status of every service

Once shopassist-web shows "healthy":

    Storefront:  http://localhost:8501
    API docs:    http://localhost:8000/docs
    Ollama:      http://localhost:11434

Stop everything with ./scripts/down.sh
EOF
