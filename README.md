# shopassist-devops

One command to bring up the entire ShopAssist platform — Postgres, the
Ollama LLM host, the FastAPI backend, and the storefront — in
the right order, fully offline after the first run.

This repo owns no application logic. Each of the four projects below owns
its own `Dockerfile`/`docker-compose.yml` and stays independently
runnable on its own; this repo's root `docker-compose.yml` just
`include:`s all four and wires them together on a shared network.

## The four projects

| Project (repo) | Role | Container(s) / image | Starts... |
|---|---|---|---|
| `shopassist-database` | Postgres | `shopassist-postgres` | first, no dependencies |
| `shopassist-model` | Ollama + model pull | `shopassist-ollama`, `shopassist-model-bootstrap` | first, no dependencies |
| `shopassist` | FastAPI backend | `shopassist-api` | after Ollama and Postgres are healthy |
| `shopassist-client` | storefront client | `shopassist-client` | after the API is healthy |

**Naming convention**: every container and every custom-built image is
named `shopassist-<role>`, not `shopassist-<repo-name>` — the role is
what you'd actually look for in `docker compose ps` or `docker compose
logs`. `shopassist-database`, `shopassist-model`, and `shopassist-client`
are project names that happen to already describe their role, so their
containers/images reuse the name as-is; `shopassist` (the backend)
doesn't, which is why its container/image is explicitly named
`shopassist-api` rather than reusing the repo name directly.
`shopassist-api` and `shopassist-client` also both set an explicit
`image:` tag in their own `docker-compose.yml` (`shopassist-api:latest`,
`shopassist-client:latest`) — without one, Compose derives an image name
from whichever project happens to be building it (`shopassist-api` if you
build from inside `shopassist/`, `shopassist-devops-api` if you build via
this repo), which is exactly the kind of inconsistency this convention
exists to avoid.

## Prerequisites

- **Docker Desktop** (or Docker Engine + Compose v2 plugin on Linux) —
  that's the only thing you install by hand.
- ~10GB free disk (mostly the LLM + Postgres + image layers)
- All five repos cloned as **siblings**, in the same parent folder:

  ```
  some-folder/
  ├── shopassist-devops/       (this repo)
  ├── shopassist-database/
  ├── shopassist-model/
  ├── shopassist/
  └── shopassist-client/
  ```

## Quick start

```bash
git clone <shopassist-devops-url>
git clone <shopassist-database-url>
git clone <shopassist-model-url>
git clone <shopassist-url>
git clone <shopassist-client-url>
cd shopassist-devops

./scripts/up.sh          # macOS / Linux
.\scripts\up.ps1          # Windows (PowerShell)
```

That's the whole "simple steps" — install Docker Desktop, clone five
repos into one folder, run one script. The script itself:

1. Confirms all four sibling projects are actually there.
2. Confirms Docker is installed and the daemon is running.
3. Creates a `.env` in this repo and in `shopassist-database`/
   `shopassist-model` from their `.env.example`, if missing (`shopassist`
   and `shopassist-client` hardcode their container-relevant defaults
   directly in their own `docker-compose.yml`, so neither needs one for
   this to work).
4. Creates the external Postgres volume (`docker volume create` is
   idempotent — safe even if it already exists).
5. Runs `docker compose up -d --build`.

First run downloads a ~2GB model and builds two images (`shopassist-api`,
`shopassist-client`) — expect several minutes. Every run after that is
fast, since the model and Postgres data persist in named Docker volumes,
not inside any container.

Watch it come up:

```bash
docker compose logs -f model-bootstrap   # model download progress
docker compose ps                         # health status of every service
```

Once `shopassist-client` shows `healthy`:

| | |
|---|---|
| Storefront | http://localhost:8501 |
| API docs | http://localhost:8000/docs |
| Ollama | http://localhost:11434 |

Stop it:

```bash
./scripts/down.sh            # keeps data (Postgres + downloaded model)
./scripts/down.sh --wipe     # deletes everything, next start is from scratch
```

(`.\scripts\down.ps1` / `.\scripts\down.ps1 -Wipe` on Windows.)

Everything after the first run works **fully offline** — Ollama and
Postgres both run locally in containers, nothing reaches out to the
internet once the images are built and the model is pulled.

## Why `include:`, not one giant compose file

Each project keeps owning its own `docker-compose.yml` and stays
independently runnable — `cd shopassist-database && docker compose up`,
`cd shopassist-model && docker compose up`, `cd shopassist && docker
compose up`, and `cd shopassist-client && docker compose up` all still work
on their own, each talking to its dependencies (if any) over
`localhost`/`host.docker.internal`. This repo's root `docker-compose.yml`
just references those four files by path and adds a shared network plus
a handful of environment overrides on top, rather than copy-pasting their
service definitions and letting them drift out of sync. If
`shopassist-database` changes its Postgres version, or `shopassist` adds
a new environment variable, this repo picks that up automatically —
nothing here needs updating for that.

Concretely, each `include:`d service keeps its own project's network
(so standalone `docker compose up` still works from inside that repo)
*and* joins this repo's `shopassist-platform` network (so the four
containers can reach each other by name — `postgres`, `ollama`, `api`,
`client` — when run together here). `api` and `client` also get their
`environment:` overridden with the real container-network URLs
(`http://ollama:11434`, `postgresql://...@postgres:5432/...`,
`http://api:8000`) in place of the `host.docker.internal` defaults each
uses when run standalone — see the comments in this repo's
`docker-compose.yml` for exactly which keys change.

## What's honestly not wired up yet

- **The model name has to be kept in sync by hand across two repos.**
  `shopassist-model/config/models.yaml` decides what actually gets
  pulled into Ollama; this repo's `.env` (`SHOPASSIST_MODEL`) decides
  what `shopassist` asks for. Change one, change the other, or they'll
  disagree and routing/generation calls will fail against a model that
  was never pulled.
- **Postgres credentials are duplicated by convention, not enforced.**
  `shopassist-database`'s `.env` sets the real `POSTGRES_USER`/
  `POSTGRES_PASSWORD`/`POSTGRES_DB`; this repo's `docker-compose.yml`
  assumes those still match its own defaults when building `api`'s
  `DATABASE_URL`. Change the former without setting the matching
  `SHOPASSIST_DATABASE_*` override here (see `.env.example`) and `api`
  will fail to authenticate against Postgres.

## CI

`.github/workflows/compose-smoke-test.yml` checks out all four sibling
repos, runs the exact same `docker-compose.yml` a developer would, and
hits the chat endpoint end to end — it exists to catch "the platform
doesn't boot together anymore," which none of the four repos' own CI (if
they have any) can see on its own, since each only tests itself in
isolation.

Two things worth knowing before it'll actually pass:

- The four projects aren't all under the same GitHub owner today
  (`shopassist` currently lives under a different account than the other
  three) — the workflow reads each repo's owner/name from repository
  variables with defaults matching what's true right now. Update the
  variables in **Settings → Secrets and variables → Actions → Variables**
  if any of them move.
- If any of the four repos are private, cross-repo checkout needs a PAT
  with access to them, stored as the `PLATFORM_CHECKOUT_TOKEN` secret —
  the default `GITHUB_TOKEN` can only check out public repos it doesn't
  own.

## Project structure

```
shopassist-devops/
├── docker-compose.yml                       root: include: + api/client overrides + shared network
├── .env.example                              platform-level knobs (ports, which model, app title, DB credential overrides)
├── scripts/
│   ├── up.sh / down.sh                       macOS / Linux
│   └── up.ps1 / down.ps1                     Windows
└── .github/workflows/
    └── compose-smoke-test.yml                checks out all 4 repos, boots the platform, smoke-tests it
```

Each of the other three infra-adjacent repos owns its own equivalent
`Dockerfile` + `docker-compose.yml` in its own root — nothing Docker-related
lives in this repo for `shopassist` or `shopassist-client`; see their READMEs.

## Troubleshooting

- **A project is "missing" per the startup script** — clone it as a
  sibling of `shopassist-devops`, not inside it.
- **`api` never goes healthy** — check `docker compose logs api`; often
  it's waiting on `ollama` to finish pulling the model, or on `postgres`
  to finish its own startup. Check `docker compose logs model-bootstrap`
  and `docker compose logs postgres` first.
- **`api` is healthy but `database_reachable: false`** — check
  `docker compose logs postgres` for a crash, and confirm
  `shopassist-database/.env`'s credentials match what `api`'s
  `DATABASE_URL` expects (see "What's honestly not wired up yet" above).
- **`client` never goes healthy** — it depends on `api` being healthy
  first; check `docker compose logs client` and `docker compose logs api`
  in that order.
- **Port already in use** — set `API_PORT` / `WEB_PORT` in this repo's
  `.env`, or `OLLAMA_PORT` in `shopassist-model`'s.
- **Chat replies are generic / routing seems off** — confirm
  `SHOPASSIST_MODEL` here matches `shopassist-model/config/models.yaml`;
  see "What's honestly not wired up yet" above.
- **Started fresh but old data is still there** — `./scripts/down.sh`
  alone preserves the Postgres volume and downloaded models on purpose;
  use `--wipe` for a genuinely clean slate.
