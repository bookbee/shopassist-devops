# shopassist-devops

One command brings up the whole ShopAssist platform — Postgres, Ollama,
the FastAPI backend, and the storefront — in dependency order, fully
offline after the first run.

This repo owns no application logic. Each project below owns its own
`Dockerfile`/`docker-compose.yml` and stays independently runnable; this
repo's root `docker-compose.yml` just `include:`s all four and adds a
shared network plus a handful of environment overrides.

## The four projects

| Project (repo)        | Role                | Container(s) / image                              | Starts...                             |
|-----------------------|---------------------|---------------------------------------------------|---------------------------------------|
| `shopassist-database` | Postgres            | `shopassist-postgres`                             | first, no dependencies                |
| `shopassist-model`    | Ollama + model pull | `shopassist-ollama`, `shopassist-model-bootstrap` | first, no dependencies                |
| `shopassist`          | FastAPI backend     | `shopassist-api`                                  | after Ollama and Postgres are healthy |
| `shopassist-client`   | storefront client   | `shopassist-client`                               | after the API is healthy              |

**Naming**: every container/image is `shopassist-<role>`, not
`shopassist-<repo-name>` — that's what you actually search for in `docker
compose ps`/`logs`. `shopassist` (the backend) is the only repo name that
doesn't already describe its role, hence `shopassist-api`. `shopassist-api`
and `shopassist-client` each set an explicit `image:` tag in their own
`docker-compose.yml` so the image name doesn't depend on which repo you
happen to build from.

## Prerequisites

- **Docker Desktop** (or Docker Engine + Compose v2 on Linux) — the only
  manual install.
- ~10GB free disk (LLM + Postgres + image layers).
- All five repos cloned as **siblings**:

  ```text
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

The script: checks all sibling projects exist, checks Docker is running,
bootstraps `.env` here and in `shopassist-database`/`shopassist-model`
from their `.env.example` if missing (`shopassist` and `shopassist-client`
hardcode their container env directly in their own `docker-compose.yml`,
so neither needs one), creates the external Postgres volume, then runs
`docker compose up -d --build`.

First run downloads a ~2GB model and builds two images
(`shopassist-api`, `shopassist-client`) — expect several minutes. Every
run after is fast; the model and Postgres data persist in named volumes,
not inside any container.

```bash
docker compose logs -f model-bootstrap   # model download progress
docker compose ps                         # health status of every service
```

Once `shopassist-client` shows `healthy`:

- Storefront — <http://localhost:8501>
- API docs — <http://localhost:8000/docs>
- Ollama — <http://localhost:11434>

Stop it:

```bash
./scripts/down.sh            # keeps data (Postgres + downloaded model)
./scripts/down.sh --wipe     # deletes everything, next start is from scratch
```

(`.\scripts\down.ps1` / `.\scripts\down.ps1 -Wipe` on Windows.)

Everything after the first run works **fully offline** — nothing reaches
the internet once images are built and the model is pulled.

## Why `include:`, not one giant compose file

Each project keeps owning its `docker-compose.yml` and stays
independently runnable on its own — `cd shopassist-database && docker
compose up` etc. all still work standalone, talking to dependencies over
`localhost`/`host.docker.internal`. This repo just references those four
files by path and layers a shared network + container-network URLs
(`postgres:5432`, `ollama:11434`, `api:8000`) on top, so nothing here
needs updating when a sibling repo changes its own compose file.

Each `include:`d service keeps its own project's network (`services:`
entries here list it explicitly, since Compose's list-merge semantics
replace rather than append) *and* joins this repo's `shopassist-platform`
network — see the comments in `docker-compose.yml` for exactly which
`environment:` keys get overridden per service.

## What's honestly not wired up yet

- **Model name is synced by hand across two repos.**
  `shopassist-model/config/models.yaml` controls what actually gets
  pulled into Ollama; this repo's `.env` (`SHOPASSIST_MODEL`) controls
  what `shopassist` asks for. Change one without the other and
  routing/generation calls fail against a model that was never pulled.
- **Postgres credentials are duplicated by convention, not enforced.**
  `shopassist-database`'s `.env` sets the real Postgres credentials; this
  repo's `docker-compose.yml` assumes they still match its own defaults
  when building `api`'s `DATABASE_URL`. Override `SHOPASSIST_DATABASE_*`
  here (see `.env.example`) if you change those.

## CI

`.github/workflows/compose-smoke-test.yml` checks out all four sibling
repos, brings the platform up the same way a developer would, and hits
the chat endpoint end to end — catches "the platform doesn't boot
together anymore," which none of the four repos' own CI can see in
isolation.

- Repo owners/names are configurable via repository variables (**Settings
  → Secrets and variables → Actions → Variables**) since `shopassist`
  currently lives under a different GitHub account than the other three.
- Private repos need a PAT with cross-repo access, stored as
  `PLATFORM_CHECKOUT_TOKEN` — the default `GITHUB_TOKEN` can't check out
  repos it doesn't own.

## Project structure

```text
shopassist-devops/
├── docker-compose.yml          root: include: + api/client overrides + shared network
├── .env.example                 platform knobs (ports, model, app title, DB credential overrides)
├── scripts/
│   ├── up.sh / down.sh          macOS / Linux
│   └── up.ps1 / down.ps1        Windows
└── .github/workflows/
    └── compose-smoke-test.yml   checks out all 4 repos, boots the platform, smoke-tests it
```

Nothing Docker-related lives in this repo for `shopassist` or
`shopassist-client` — each owns its own `Dockerfile`/`docker-compose.yml`;
see their READMEs.

## Troubleshooting

- **A project is "missing" per the startup script** — clone it as a
  sibling of `shopassist-devops`, not inside it.
- **`api` never goes healthy** — check `docker compose logs api`; often
  it's waiting on `ollama` or `postgres`. Check `docker compose logs
  model-bootstrap` and `docker compose logs postgres` first.
- **`api` is healthy but `database_reachable: false`** — check `docker
  compose logs postgres`, and confirm `shopassist-database/.env`'s
  credentials match `api`'s `DATABASE_URL` (see "What's honestly not
  wired up yet").
- **`client` never goes healthy** — it depends on `api` first; check
  `docker compose logs client` then `docker compose logs api`.
- **Port already in use** — set `API_PORT`/`WEB_PORT` in this repo's
  `.env`, or `OLLAMA_PORT` in `shopassist-model`'s.
- **Chat replies are generic / routing seems off** — confirm
  `SHOPASSIST_MODEL` here matches `shopassist-model/config/models.yaml`.
- **Started fresh but old data is still there** — `./scripts/down.sh`
  alone preserves the Postgres volume and downloaded models on purpose;
  use `--wipe` for a genuinely clean slate.
