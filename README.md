# shopassist-devops

One command to bring up the entire ShopAssist platform — Postgres, the
Ollama LLM host, the FastAPI backend, and the Streamlit storefront — in
the right order, fully offline after the first run.

This repo owns no application logic. `shopassist` and `shopassist-streamlit`
stay pure application code with zero Docker/infra files in them; this repo
holds their Dockerfiles instead (see `docker/`), plus the root
`docker-compose.yml` that wires all four projects together.

## The four projects, in the order they start

```
shopassist-database  (Postgres)         — starts first, no dependencies
shopassist-model     (Ollama + models)  — starts first, no dependencies
shopassist            (FastAPI backend)  — waits for Ollama to be healthy
shopassist-streamlit  (storefront)       — waits for the backend to be healthy
```

`shopassist-database` and `shopassist-model` each own their own
`docker-compose.yml` (they're self-contained infra projects already) —
this repo's root compose file pulls both in via Compose's `include:`
directive, unmodified, and adds the two application containers plus a
shared network so everything can reach everything else.

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
  └── shopassist-streamlit/
  ```

## Quick start

```bash
git clone <shopassist-devops-url>
git clone <shopassist-database-url>
git clone <shopassist-model-url>
git clone <shopassist-url>
git clone <shopassist-streamlit-url>
cd shopassist-devops

./scripts/up.sh          # macOS / Linux
.\scripts\up.ps1          # Windows (PowerShell)
```

That's the whole "simple steps" — install Docker Desktop, clone five
repos into one folder, run one script. The script itself:

1. Confirms all four sibling projects are actually there.
2. Confirms Docker is installed and the daemon is running.
3. Creates a `.env` in this repo and in `shopassist-database`/
   `shopassist-model` from their `.env.example`, if missing.
4. Creates the external Postgres volume (`docker volume create` is
   idempotent — safe even if it already exists).
5. Runs `docker compose up -d --build`.

First run downloads a ~2GB model and builds four images — expect several
minutes. Every run after that is fast, since the model and Postgres data
persist in named Docker volumes, not inside any container.

Watch it come up:

```bash
docker compose logs -f model-bootstrap   # model download progress
docker compose ps                         # health status of every service
```

Once `shopassist-web` shows `healthy`:

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
independently runnable — `cd shopassist-database && docker compose up`
still works on its own, same as before this repo existed. This repo's
root `docker-compose.yml` just references those two files by path and
adds the two application containers (`api`, `web`) on top, rather than
copy-pasting their service definitions and letting them drift out of
sync. If `shopassist-database` changes its Postgres version, this repo
picks that up automatically — nothing here needs updating.

## What's honestly not wired up yet

- **`shopassist`'s API doesn't actually use the Postgres container.**
  Its own database schema (`customers`/`items`/`sessions`/`orders`/
  `order_items`) doesn't match `shopassist-database`'s
  (`customers`/`products`/`orders`/`order_items`) — see that repo's
  README. `shopassist`'s container still runs against its own local
  SQLite fallback, rebuilt fresh on every start. Postgres comes up as
  part of this platform anyway (so the full stack is exercised and
  ready for when that reconciliation happens), it's just not on the
  request path today.
- **The model name has to be kept in sync by hand across two repos.**
  `shopassist-model/config/models.yaml` decides what actually gets
  pulled into Ollama; this repo's `.env` (`SHOPASSIST_MODEL`) decides
  what `shopassist` asks for. Change one, change the other, or they'll
  disagree and routing/generation calls will fail against a model that
  was never pulled.

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
├── docker-compose.yml                       root: include: + api/web services + shared network
├── .env.example                              platform-level knobs (ports, which model, app title)
├── docker/
│   ├── shopassist/Dockerfile                 builds the FastAPI backend from ../shopassist
│   └── shopassist-streamlit/Dockerfile       builds the storefront from ../shopassist-streamlit
├── scripts/
│   ├── up.sh / down.sh                       macOS / Linux
│   └── up.ps1 / down.ps1                     Windows
└── .github/workflows/
    └── compose-smoke-test.yml                checks out all 4 repos, boots the platform, smoke-tests it
```

## Troubleshooting

- **A project is "missing" per the startup script** — clone it as a
  sibling of `shopassist-devops`, not inside it.
- **`api` never goes healthy** — check `docker compose logs api`; often
  it's waiting on `ollama` to finish pulling the model still. Check
  `docker compose logs model-bootstrap` first.
- **Port already in use** — set `API_PORT` / `WEB_PORT` in this repo's
  `.env`, or `OLLAMA_PORT` in `shopassist-model`'s.
- **Chat replies are generic / routing seems off** — confirm
  `SHOPASSIST_MODEL` here matches `shopassist-model/config/models.yaml`;
  see "What's honestly not wired up yet" above.
- **Started fresh but old data is still there** — `./scripts/down.sh`
  alone preserves the Postgres volume and downloaded models on purpose;
  use `--wipe` for a genuinely clean slate.
