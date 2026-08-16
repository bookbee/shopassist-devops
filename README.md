# shopassist-devops

One command brings up the whole ShopAssist platform — Postgres, Ollama,
the FastAPI backend, and the storefront — in dependency order, fully
offline after the first run.

This repo owns no application logic. Each project below owns its own
`Dockerfile`/`docker-compose.yml` and stays independently runnable; this
repo's root `docker-compose.yml` just `include:`s all four and adds a
shared network plus a handful of environment overrides.

## What you're actually running

**Start here if this is your first contact with the project.** ShopAssist
is a customer-support chatbot for an online store. A shopper types
something like *"where's my order ord-1001, and what's your return
policy?"* into a web storefront, and gets one coherent reply back.

Five containers cooperate to produce that reply:

```text
  you, in a browser
        │
        ▼
  [ client ]        the storefront (Streamlit). Just a UI - no AI here.
        │  HTTP
        ▼
  [ api ]           the brain (FastAPI). Decides what the question means,
        │           who should answer it, and writes the final reply.
        ├──────────────► [ ollama ]     runs the language model, on your CPU
        ├──────────────► [ classifier ] scores the message's sentiment
        └──────────────► [ postgres ]   the real order/customer database
```

The interesting part is what `api` does with one message:

1. **Mask personal data** — strip emails/phones/addresses *before* any of
   it reaches the language model.
2. **Split the question** — a language model breaks "where's my order
   **and** what's your return policy" into two separate sub-tasks.
3. **Route each sub-task to a specialist** — order questions go to an
   agent that queries the Postgres database; policy questions go to an
   agent that searches the shipped PDF policy documents.
4. **Write one reply** — a final language-model call merges every
   specialist's findings into a single answer.

Nothing here calls a paid cloud API. The language model runs locally in
the `ollama` container, which is why replies take tens of seconds on a
laptop rather than being instant — that trade-off is the point, not a
bug. See [Concepts, and where to read more](#concepts-and-where-to-read-more)
at the bottom for what each term above means.

## The four projects

| Project (repo)        | Role                | Container(s) / image                                                                                           | Starts...                             |
|-----------------------|---------------------|----------------------------------------------------------------------------------------------------------------|---------------------------------------|
| `shopassist-database` | Postgres            | `shopassist-postgres`                                                                                          | first, no dependencies                |
| `shopassist-model`    | Ollama + classifier | `shopassist-ollama`, `shopassist-ollama-bootstrap`, `shopassist-classifier`, `shopassist-classifier-bootstrap` | first, no dependencies                |
| `shopassist-service`  | FastAPI backend     | `shopassist-api`                                                                                               | after Ollama and Postgres are healthy |
| `shopassist-client`   | storefront client   | `shopassist-client`                                                                                            | after the API is healthy              |

**Naming**: every container and locally-built image is
`shopassist-<role>`, not `shopassist-<repo-name>` — that's what you
actually search for in `docker compose ps`/`logs`. `shopassist-service`
(the backend) is the only repo name that doesn't already describe its
role, hence `shopassist-api`.

Every service that builds from source sets an explicit `image:` tag in
its own `docker-compose.yml`. That matters: without one, Compose derives
the image name from *the project directory you happened to build from*,
so the classifier image was `shopassist-devops-classifier` when built via
this repo and `shopassist-model-classifier` when built from its own — the
same image under two names, neither matching its `container_name`.
`classifier` and `classifier-bootstrap` deliberately share one
`shopassist-classifier` image (identical build context, they differ only
by `command:`), so it's built once rather than duplicated.

Images you should see after a build — pulled upstream images keep their
own names, since nothing here rebuilds them:

```text
ollama/ollama:latest            pulled     the LLM server
pgvector/pgvector:pg17          pulled     Postgres + pgvector
shopassist-api:latest           built      shopassist-service
shopassist-client:latest        built      shopassist-client
shopassist-classifier:latest    built      shopassist-model (2 containers)
shopassist-ollama-bootstrap     built      shopassist-model (model pull job)
```

## Prerequisites

- **Docker Desktop 4.22+** (or Docker Engine + **Compose v2.20+** on
  Linux) — the only manual install. You do **not** need Python, Postgres,
  Ollama, an NVIDIA GPU, or any API key on your machine. Everything runs
  in containers.

  The version floor is real, not cautious rounding: this repo's
  `docker-compose.yml` uses the top-level `include:` element and
  `depends_on: { required: false }`, both of which landed in Compose
  2.20. An older Compose doesn't degrade — it fails while parsing the
  file, before anything starts. Check with `docker compose version`.
- **At least 8GB of RAM allocated to Docker**, on a machine with 16GB
  total. This is the single most common cause of a stack that builds fine
  and then dies mid-conversation: the language model alone wants ~4GB
  resident. Check and raise it in **Docker Desktop → Settings →
  Resources → Memory**; on Linux, Docker uses host RAM directly and
  there's nothing to set.

  The compose files cap three services (`ollama` 6g, `classifier` 4g,
  `api` 2g). Those are ceilings, not reservations — they don't all run at
  peak together — but 8GB is the point below which the model starts
  getting killed mid-reply.
- **~15GB free disk**, and ~8–10GB of downloads on the first run only
  (images, the language model, and the classification models — itemised
  under [Quick start](#quick-start)).
- An internet connection **for the first run only** — it downloads images
  and models. After that the platform runs fully offline. It reaches
  Docker Hub, **`download.pytorch.org`** (the classifier's CPU-only torch
  wheel), **`huggingface.co`** (the two classification checkpoints), and
  PyPI. Worth knowing if you're building behind a restrictive proxy —
  Docker Hub alone isn't enough.
- **Host ports free**: `5432` (Postgres), `8000` (API), `8100`
  (classifier), `8501` (storefront), `11434` (Ollama). Plus `9090`/`3000`
  if you add the observability overlay, and `1234` for LM Studio. The
  first two are remappable via `API_PORT`/`WEB_PORT` in `.env`.
- **`git`**, to clone the five repos as **siblings**:

  ```text
  some-folder/
  ├── shopassist-devops/       (this repo)
  ├── shopassist-database/
  ├── shopassist-model/
  ├── shopassist-service/
  └── shopassist-client/
  ```

- For `./scripts/up.sh` itself: **bash and curl**. One path also needs
  **`python3` on the host** — the 768-dimension embedding probe that runs
  only in `lms` mode with `LMSTUDIO_EMBEDDING_MODEL` set. Every other
  mode needs neither.

### What each project pulls or builds

Nothing in this table is something you install by hand — it's what the
first `docker compose up --build` fetches, listed so you can pre-seed a
machine, audit the supply chain, or work out what a restricted network
will block.

| Project | Base / pulled images | Installed into the image | Downloaded at runtime |
| --- | --- | --- | --- |
| `shopassist-database` | `pgvector/pgvector:pg17` | — (no build) | — |
| `shopassist-model` | `ollama/ollama:latest`, `python:3.12-slim` ×2 | **classifier**: CPU-only `torch` (from PyTorch's own index), transformers, fastapi, uvicorn[standard], sentencepiece, protobuf, pydantic, PyYAML, prometheus-fastapi-instrumentator · **bootstrap**: requests, PyYAML | `llama3.2:3b` + `nomic-embed-text` into `shopassist-ollama-models`; `nlptown/bert-base-multilingual-uncased-sentiment` + `MoritzLaurer/deberta-v3-base-zeroshot-v2.0` into `shopassist-classifier-models` |
| `shopassist-service` | `python:3.12-slim` | fastapi, uvicorn[standard], pydantic, python-dotenv, openai, SQLAlchemy, psycopg2-binary, requests, faiss-cpu, numpy, pypdf, reportlab, langchain-text-splitters, langfuse, prometheus-fastapi-instrumentator — all **exact-pinned**, see that repo's `requirements.txt` for why | — |
| `shopassist-client` | `python:3.12-slim` | streamlit, requests, PyYAML, python-dotenv, Pillow | — |
| `shopassist-devops` | — | — (owns no application code) | — |

Two optional extras, neither part of a default run: the observability
overlay adds `prom/prometheus` and `grafana/grafana` (see
[below](#optional-observability-prometheus--grafana)), and
`shopassist-database`'s `rag-init` profile installs psycopg2-binary,
openai, pypdf and openpyxl into a throwaway `python:3.12-slim` —
see the note on it in [What you're *not* running](#what-youre-not-running).

### Running a project outside Docker

Only relevant if you're developing on one project directly rather than
running the platform. Each needs **Python 3.12** and its own
`requirements.txt`; `shopassist-service` additionally has
`evaluation/requirements-eval.txt` (scikit-learn, numpy) for the offline
eval harness.

One gap to know about: `shopassist-model/classifier/requirements.txt`
does **not** list `torch`. That's deliberate for the image — its
`Dockerfile` installs the CPU-only wheel from PyTorch's own index first,
so pip doesn't select the multi-GB CUDA build from PyPI — but it means a
bare `pip install -r requirements.txt` on your machine gives you a
`transformers` that can't load a model. Install torch first, the same way
the Dockerfile does.

### What you're *not* running

`shopassist-database` ships pgvector, a `VECTOR(768) document_chunks`
table, `postgres/rag_sources/`, and a `rag-init` profile — none of which
the running platform touches. The API's retrieval is a FAISS index built
in-process at startup from `shopassist-service/docs/*.pdf`; nothing in
the service ever queries `document_chunks`. So **don't run `docker
compose --profile rag up rag-init`** as part of bringing the platform
up: it's a separate, standalone exploration of the pgvector path, it
expects an Ollama reachable on `host.docker.internal`, and it adds
nothing to what the storefront answers with.

## Quick start

```bash
git clone <shopassist-devops-url>
git clone <shopassist-database-url>
git clone <shopassist-model-url>
git clone <shopassist-service-url>
git clone <shopassist-client-url>
cd shopassist-devops

./scripts/up.sh          # macOS / Linux
.\scripts\up.ps1          # Windows (PowerShell)
```

The script checks all sibling projects exist, checks Docker is running,
creates `.env` here from `.env.example` if it's missing, then runs
`docker compose up -d --build`.

It's a convenience, not a prerequisite — plain `docker compose up -d
--build` from this directory does the same thing. Every setting has a
working default baked into the compose files, so **no `.env` file
anywhere is required to start.** (Each project also ships its own
`.env.example`, but those matter only when running that project
standalone — see [Configuration](#configuration-edit-env-here-not-in-a-sibling-repo).)

**Budget real time and bandwidth for the first run** — roughly **8–10GB
of downloads in total**, and anywhere from 15 minutes on a fast
connection to well over an hour on a slow one:

| What | Size |
| --- | --- |
| `ollama/ollama` image | ~2.5–2.8GB |
| `llama3.2:3b` chat model + `nomic-embed-text` | ~2.2GB |
| encoder classification models (Hugging Face) | ~1.2GB |
| `pgvector/pgvector:pg17` image | ~0.5GB |
| Python base images + pip dependencies for the three built images | ~2GB |

Only the first run pays this. Everything lands in named volumes and the
image cache, so later starts take seconds and need no network at all.

Watch it happen rather than staring at a silent terminal:

```bash
docker compose logs -f ollama-bootstrap    # model download progress
docker compose ps                          # health of every service
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

## Choosing an LLM backend

Three ways to run the language model, one switch:

| Mode | What runs the model | Extra install | Speed |
| --- | --- | --- | --- |
| `docker` **(default)** | the bundled `ollama` container | **none** | slowest — CPU-only |
| `local` | an Ollama installed on this machine | Ollama | fast — uses your GPU |
| `lms` | a model served by LM Studio | LM Studio | fast — uses your GPU |

**`docker` is the default**, and it's what a fresh clone runs with no
configuration at all — the only mode that needs nothing installed beyond
Docker Desktop. `./scripts/up.sh` on a new machine creates `.env` from
`.env.example` (which ships `SHOPASSIST_LLM_MODE=docker`) and starts the
bundled Ollama container. Expect slow replies; that's CPU-only inference,
and the other two modes are the cure once you have a local runtime.

Change it once in `shopassist-devops/.env` when you do:

```env
SHOPASSIST_LLM_MODE=lms      # lms | local | docker
```

…and `./scripts/up.sh` uses it every time. Override for a single run
without editing anything:

```bash
./scripts/up.sh --docker
./scripts/up.sh --local
./scripts/up.sh --lms
```

Windows: `.\scripts\up.ps1 -Docker | -Local | -Lms`.

The script prints which mode it resolved and where from, so there's never
any doubt:

```text
==> LLM mode: lms (from SHOPASSIST_LLM_MODE in .env)
```

There is **one** `docker-compose.yml` and no per-mode overlay files. Each
mode is just a set of environment values plus, where the bundled Ollama
isn't wanted, `--scale ollama=0` — which works because `api`'s dependency
on the model-pull job is declared `required: false`, so a scaled-to-zero
Ollama is skipped instead of blocking startup. Whichever mode you pick,
`GENERATIVE_PROVIDER=gemini` still layers on top to route just the
customer-facing reply to the cloud.

To confirm what's actually loaded, at any time:

```bash
docker logs shopassist-api | grep "LLMInferenceService ready"
```

## Using a native Ollama (much faster)

The bundled `ollama` container is **CPU-only**. Docker Desktop on macOS
can't pass through the Apple Silicon GPU, and on Linux the container sees
an NVIDIA GPU only if you've installed the Container Toolkit. If you
already run Ollama natively, pointing the platform at it is the single
biggest speed win available:

```bash
./scripts/up.sh --local    # the Ollama on this machine
./scripts/up.sh --docker   # back to the bundled container
```

Or set it once and forget it — `SHOPASSIST_LLM_MODE=local` in
`shopassist-devops/.env` makes a bare `./scripts/up.sh` use it, with the
flags still overriding for a single run. See
[Choosing an LLM backend](#choosing-an-llm-backend).

Measured on the same machine, same models, same question ("where is my
order ord-1001, and what is your return policy" — a two-agent query):

| | Bundled container (CPU) | Native Ollama (GPU) | Hybrid: Gemini for the reply |
| --- | --- | --- | --- |
| One two-agent chat turn | ~318s | ~32s | **~17s** |
| `api` warm-up before healthy | ~90s | ~10s | ~10s |
| Needs a key / internet | no | no | yes |

(Hybrid = native Ollama for routing and reasoning, `GENERATIVE_PROVIDER=gemini`
for the customer-facing reply — see
[Configuration](#configuration-edit-env-here-not-in-a-sibling-repo). The
three options compose: pick the fastest combination your setup allows.)

Equivalent long form, if you'd rather not use the script — the mode is
just environment values plus skipping the bundled Ollama:

```bash
OLLAMA_API_BASE_URL=http://host.docker.internal:11434 \
EMBEDDING_API_BASE_URL=http://host.docker.internal:11434 \
  docker compose up -d --scale ollama=0 --scale ollama-bootstrap=0
```

### Pull both models natively first

The API needs a chat model **and** an embedding model. A native install
that's only ever been used for chat usually has just the first:

```bash
ollama pull llama3.2:3b
ollama pull nomic-embed-text
ollama list                       # both must be listed
```

`--local` checks for both and refuses to start if either is missing.
That check matters because a missing `nomic-embed-text` fails *quietly*:
RAG ingestion skips every chunk and policy questions come back with
nothing retrieved, while chat still appears to work.

### Why it's an overlay, not just a URL change

Setting `OLLAMA_API_BASE_URL` by hand isn't enough. The bundled container
publishes host port **11434** — the same port your native Ollama listens
on. Leave it running and the two fight over the binding, so which one
answers depends on load order and you get intermittently wrong results.
`--local` therefore also scales `ollama` and `ollama-bootstrap` to zero
(freeing that port and ~3GB of RAM). `api`'s dependency on the model-pull
job is declared `required: false`, so it's skipped rather than blocking
startup.

Everything else — Postgres, the classifier, the storefront — is
unchanged, so this is purely a swap of where the language model runs.

## Using LM Studio (or any OpenAI-compatible server)

Nothing in this project is Ollama-specific. `shopassist-service` talks to
an OpenAI-compatible `/v1` endpoint through the `openai` SDK — which is
exactly what **LM Studio**, llama.cpp's server, and vLLM all expose. So
swapping in a model you're serving yourself is a change of endpoint and
model id, not a code change.

```bash
# 1. In LM Studio: load the model, then Developer tab -> Start Server.
#    (The server is separate from the chat UI. Loading a model is not enough
#     - this is the most common reason the next step fails.)

# 2. Get the exact model ids it serves:
curl http://localhost:1234/v1/models

# 3. Run the platform against it:
LMSTUDIO_MODEL=google/gemma-4-e2b ./scripts/up.sh --lms

# ...or, if you also loaded a 768-dim embedding model, run everything on
# LM Studio and leave Ollama out of the request path entirely:
LMSTUDIO_MODEL=google/gemma-4-e2b \
LMSTUDIO_EMBEDDING_MODEL=text-embedding-nomic-embed-text-v1.5 \
  ./scripts/up.sh --lms
```

Verified working with `google/gemma-4-e2b` + `text-embedding-nomic-embed-text-v1.5`:
87 documents ingested, multi-agent routing intact, ~10-20s per chat turn.

### The one real incompatibility: structured output

Ollama accepts `response_format={"type": "json_object"}`. **LM Studio
rejects it** — `'response_format.type' must be 'json_schema' or 'text'` —
and every structured call (routing, decomposition, agent reasoning) 400s,
collapsing the whole turn into the generic "unexpected error" reply.

`LOCAL_STRUCTURED_MODE` handles this, and the overlay sets it for you:

| Local server | `LOCAL_STRUCTURED_MODE` | Mechanism |
| --- | --- | --- |
| Ollama | `json_object` (default) | `response_format={"type":"json_object"}` |
| LM Studio, and other json_schema-only servers | `parse` | OpenAI SDK's `.parse()`, which sends a JSON schema |

`parse` is the same path Gemini already used, so this reuses existing code
rather than adding a third mechanism. If you point the platform at some
other OpenAI-compatible server and every structured call 400s, this is the
knob. The startup log always states which is active:

```text
LLMInferenceService ready | chat_endpoint=http://host.docker.internal:1234 (structured=parse)
  embedding_endpoint=http://host.docker.internal:1234 | ROUTER=local:google/gemma-4-e2b ...
```

Put `LMSTUDIO_MODEL` (and optionally `LMSTUDIO_PORT`,
`LMSTUDIO_EMBEDDING_MODEL`) in `shopassist-devops/.env` to avoid repeating
it — `./scripts/up.sh` reads that file for these, with anything set in your
shell taking precedence, matching how Compose itself resolves variables.

Use the **id from `/v1/models` verbatim** — it isn't the display name in
the LM Studio UI, and a mismatch returns 404 on every call. `--lms`
checks the server is up and that the id really is being served, listing
the available ids if not, rather than letting you find out one failed chat
later.

### Embeddings: Ollama by default, LM Studio if you have a 768-dim model

The chat model can be anything. The **embedding** model can't: it must
return exactly 768 floats, to match `services/rag.py`'s FAISS index and
`shopassist-database`'s `VECTOR(768)` column. A typical LM Studio setup
has one chat model loaded and no embedding model, so sending embeddings
there would break every RAG lookup — quietly, because ingestion just skips
chunks it can't embed.

So the overlay splits the two:

| Role | Endpoint |
| --- | --- |
| router, decomposer, agent reasoning, generative | LM Studio, `host.docker.internal:1234` |
| embeddings | bundled `ollama` container, `ollama:11434` |

They coexist happily — different ports, no conflict. The startup log shows
both, so you can always confirm what's actually wired:

```text
LLMInferenceService ready | chat_endpoint=http://host.docker.internal:1234
  embedding_endpoint=http://ollama:11434 | ROUTER=local:google/gemma-4-e2b ...
```

If you *do* have one loaded, set `LMSTUDIO_EMBEDDING_MODEL` and both roles
run on LM Studio. `--lms` then checks two things before starting: that
the id really is being served, and that it returns **exactly 768
dimensions** — a wrong width doesn't error at runtime, it just makes every
retrieval meaningless and poisons the stored vectors, so it's worth
failing fast on.

### Is the Ollama container needed in LM Studio mode?

Only if embeddings still run on it. `--lms` decides for you:

| `LMSTUDIO_EMBEDDING_MODEL` | Embeddings | `ollama` container | Containers |
| --- | --- | --- | --- |
| unset | bundled Ollama | **started** — it's serving them | 5 |
| set | LM Studio | **not started** | 4 |

So if you picked `--lms` and still see `shopassist-ollama` running, that's
almost certainly why: it's doing the embeddings. `docker logs
shopassist-api | grep "LLMInferenceService ready"` shows
`embedding_endpoint=http://ollama:11434` when that's the case.

The other way to see it running is invoking `docker compose up -d` by
hand — the `--scale ollama=0` that skips it lives in `./scripts/up.sh`, so
a raw Compose command always starts everything.

With it set, nothing in the request path touches Ollama, so the container
isn't started at all — no idle ~3GB, and no 2GB chat-model pull on a first
run. `--lms` handles that for you.

Invoking Compose by hand, the two forms are:

```bash
# chat on LM Studio, embeddings on the bundled Ollama
OLLAMA_API_BASE_URL=http://host.docker.internal:1234 \
LOCAL_STRUCTURED_MODE=parse SHOPASSIST_MODEL=google/gemma-4-e2b \
  docker compose up -d

# everything on LM Studio, no Ollama container at all
OLLAMA_API_BASE_URL=http://host.docker.internal:1234 \
EMBEDDING_API_BASE_URL=http://host.docker.internal:1234 \
LOCAL_STRUCTURED_MODE=parse SHOPASSIST_MODEL=google/gemma-4-e2b \
EMBEDDING_MODEL=text-embedding-nomic-embed-text-v1.5 \
  docker compose up -d --scale ollama=0 --scale ollama-bootstrap=0
```

The script exists so you don't have to type any of that — and it
validates the model ids and the 768-dim requirement first.

### Which one should you use?

| | Bundled Ollama | Native Ollama | LM Studio | Gemini |
| --- | --- | --- | --- | --- |
| Extra install | none | Ollama | LM Studio | none |
| Needs internet | first run only | first run only | first run only | every call |
| Needs an API key | no | no | no | yes |
| Speed on a laptop | slowest | fast | fast | fastest |
| Pick your own model | via `config/generative.yaml` | `ollama pull` | anything in LM Studio | Gemini family only |

They're not exclusive: the fastest setup measured here is LM Studio or
native Ollama for the frequent routing/reasoning steps, with
`GENERATIVE_PROVIDER=gemini` for the customer-facing reply.

## Configuration: edit `.env` *here*, not in a sibling repo

Out of the box the platform needs **no keys and no accounts** — every
model runs locally in the `ollama` and `classifier` containers.

When you do want to change something, change it in
**`shopassist-devops/.env`**. This repo is the platform's **control
plane**: every setting that describes how the pieces are wired together,
or which external service they use, is decided here and pushed down into
the containers.

| Lives in `shopassist-devops` (control plane) | Lives in each project (its own metadata) |
| --- | --- |
| Which LLM provider each role uses, and the Gemini key | The service's `APP_TITLE`/`APP_VERSION`, its CORS origins |
| Model tags — `SHOPASSIST_MODEL`, `GEMINI_MODEL` | Which models exist at all: `shopassist-model/config/*.yaml` |
| Where Ollama, Postgres and the classifier live | The database schema and seed data |
| Database credentials | The storefront's palette and copy (`config.yaml`) |
| Timeouts, rate limit, log level, published ports | Each project's `Dockerfile` and its own compose file |
| Langfuse credentials and tracing on/off | — |

The rule of thumb: **if two projects have to agree on it, it belongs
here.** A model tag, a password, or a timeout that only one side changes
is a bug waiting to happen — that's what this repo exists to prevent.

**Secrets live here and only here.** The Gemini and Langfuse credentials
were previously duplicated in `shopassist-service/.env`; they now have a
single home in `shopassist-devops/.env` (git-ignored). A sibling project's
`.env` still works for running *that project* standalone — it just has no
say over the platform.

> **The subtle bit, worth knowing before you customise:** Compose resolves
> a `${VAR}` inside an `include:`d file against **that file's own
> directory `.env`**, not this one. So a personal
> `shopassist-service/.env` used to silently change how the whole platform
> ran — one machine on a cloud model with API-key auth enforced, another
> fully local, from identical git checkouts. Everything that could drift
> that way (`*_PROVIDER`, `GEMINI_API_KEY`, `LANGFUSE_*`, `API_KEY`,
> `DATABASE_URL`, timeouts, model tags) is now pinned explicitly in this
> repo's `docker-compose.yml`, defaulting to the fully-local
> configuration. Sibling `.env` files still work for running that project
> **standalone** — they just no longer leak into the platform.

Common changes, all in `shopassist-devops/.env`:

```env
# Use Google Gemini for the customer-facing reply instead of the local
# model - much faster, but needs a key and an internet connection. The
# other roles stay local, so only the step the user waits on goes out.
GENERATIVE_PROVIDER=gemini
GEMINI_API_KEY=your-key-here
GEMINI_MODEL=gemini-2.5-flash

# Free up ports that are already taken on your machine.
API_PORT=8000
WEB_PORT=8501

# Give slow machines longer before the UI reports a timeout (seconds).
CHAT_TIMEOUT_SECONDS=360
```

## Optional: observability (Prometheus + Grafana)

Not part of the default stack above — an opt-in overlay, layered on once
the platform is already running:

```bash
docker compose -f docker-compose.yml \
                -f observability/docker-compose.observability.yml up -d
```

- Prometheus — <http://localhost:9090> — scrapes `GET /metrics` on
  `shopassist-service`'s `api` and `shopassist-model`'s `classifier` (both expose
  it via `prometheus-fastapi-instrumentator`).
- Grafana — <http://localhost:3000> (default `admin`/`admin`, override via
  `GRAFANA_ADMIN_PASSWORD`) — the Prometheus datasource and a "ShopAssist
  Overview" dashboard (request rate, p95 latency, 5xx rate, all split by
  service) are provisioned automatically, nothing to click through.

**v1 scope, deliberately**: generic HTTP-layer metrics only. Not yet
built, and called out here rather than silently missing: log aggregation
(Loki/Promtail — `docker compose logs` is still it for now), custom
business metrics (RAG query counts, agent-routing counts, LLM call
latency), a `postgres_exporter` for Postgres-level metrics, and Ollama
metrics (no native Prometheus support to hook into). Natural follow-ups
once this base layer earns its keep.

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
  `shopassist-model/config/generative.yaml` controls what actually gets
  pulled into Ollama; this repo's `.env` (`SHOPASSIST_MODEL`) controls
  what `shopassist-service` asks for. They agree today (`llama3.2:3b` in
  both, and in `shopassist-service`'s own standalone default), but nothing
  enforces it — change one without the other and every routing/generation
  call fails against a model that was never pulled. If you do change it,
  check the tag exists first; an invalid tag makes `ollama-bootstrap` exit
  non-zero and `api` never starts:

  ```bash
  curl -so /dev/null -w '%{http_code}\n' \
    https://registry.ollama.ai/v2/library/llama3.2/manifests/3b     # 200 = real tag
  ```

- **Postgres credentials** used to be duplicated by convention and
  drifted easily — the container took them from `shopassist-database`'s
  `.env` while `api`'s connection string used this repo's defaults, so
  changing the password in one place broke authentication with nothing
  explaining why. Both sides now come from the same
  `SHOPASSIST_DATABASE_USER`/`_PASSWORD`/`_NAME` variables in *this*
  repo's `.env` (see `.env.example`). `shopassist-service` has no fallback
  database at all, so a mismatch is a hard startup failure for `api`,
  never a silent downgrade to something local.
- **`classifier` has no `depends_on` from `api`, deliberately.** It *is*
  on the live chat path (orchestrator steps 1.5/1.6 classify each
  message's sentiment and topic, which shape the reply's tone and
  emphasis), and it's used by the offline ingestion pipeline too. But both
  calls fail soft to `label="unknown"`, in which case the reply is
  generated exactly as it would be without them — so a classifier that's
  down degrades the answer slightly rather than blocking startup. Making
  it a hard dependency would trade that graceful path for an outage.

## CI

`.github/workflows/compose-smoke-test.yml` checks out all four sibling
repos, brings the platform up the same way a developer would, and hits
the chat endpoint end to end — catches "the platform doesn't boot
together anymore," which none of the four repos' own CI can see in
isolation.

- Repo owners/names are configurable via repository variables (**Settings
  → Secrets and variables → Actions → Variables**) — set them if you fork
  the whole platform or a repo moves owner.
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

Nothing Docker-related lives in this repo for `shopassist-service` or
`shopassist-client` — each owns its own `Dockerfile`/`docker-compose.yml`;
see their READMEs.

## Troubleshooting

- **A project is "missing" per the startup script** — clone it as a
  sibling of `shopassist-devops`, not inside it.
- **`api` never goes healthy** — check `docker compose logs api`; often
  it's waiting on `ollama` or `postgres`. Check `docker compose logs
  ollama-bootstrap` and `docker compose logs postgres` first.
- **`api` is healthy but `database_reachable: false`** — check `docker
  compose logs postgres`, and confirm `shopassist-database/.env`'s
  credentials match `api`'s `DATABASE_URL` (see "What's honestly not
  wired up yet").
- **`client` never goes healthy** — it depends on `api` first; check
  `docker compose logs client` then `docker compose logs api`.
- **Port already in use** — set `API_PORT`/`WEB_PORT` in this repo's
  `.env`, or `OLLAMA_PORT` in `shopassist-model`'s.
- **Chat replies are generic / routing seems off** — confirm
  `SHOPASSIST_MODEL` here matches `shopassist-model/config/generative.yaml`.
- **Started fresh but old data is still there** — `./scripts/down.sh`
  alone preserves the Postgres volume and downloaded models on purpose;
  use `--wipe` for a genuinely clean slate.
- **The storefront says "AI Assistant is currently unavailable"** — the
  usual cause is the UI giving up before the API finished, not the API
  failing. One chat turn on a CPU-only laptop legitimately takes
  150–360s. Confirm with `docker compose logs -f api`: if it's still
  logging LLM calls, raise `CHAT_TIMEOUT_SECONDS` in this repo's `.env`
  (it drives both the UI's read timeout and the API's own cap together).
- **Chat fails instantly with a "model not found" style error** — Ollama
  has no such tag. Check what was actually pulled versus what the API
  asks for:

  ```bash
  docker compose exec ollama ollama list           # what exists
  docker compose exec api env | grep OLLAMA_       # what's requested
  ```

  Every `OLLAMA_*_MODEL` must appear in that list — including
  `OLLAMA_DECOMPOSER_MODEL`, which runs on every single message.
- **`ollama-bootstrap` exited non-zero and `api` never started** — that's
  the intended chain: `api` waits for the model pull to *succeed*, so a
  bad tag stops the stack loudly instead of failing later on every chat.
  `docker compose logs ollama-bootstrap` names the tag it couldn't pull.
- **A chat reply mentions no real order, or the account looks empty** —
  log in as one of the seeded customers (`alum-1001` … `alum-1010`,
  password identical to the user ID). Any other ID authenticates fine but
  has no orders behind it.
- **Replies are slow (tens of seconds to minutes)** — expected with the
  bundled CPU-only Ollama. If you have Ollama installed natively, use
  `./scripts/up.sh --local` (see [Using a native
  Ollama](#using-a-native-ollama-much-faster)) — ~10x faster in testing.
  Otherwise route just the customer-facing step to Gemini.
- **Switched to `--local` and now policy questions return nothing** —
  your native Ollama is missing `nomic-embed-text`. Chat still works, but
  every RAG lookup silently retrieves nothing. `ollama pull
  nomic-embed-text`, then restart.
- **Two Ollamas fighting over port 11434** — don't set
  `OLLAMA_API_BASE_URL` by hand while the bundled container is still
  running; use the overlay, which stops it. `lsof -nP -iTCP:11434
  -sTCP:LISTEN` shows who currently holds the port.
- **It behaves differently on your machine than a colleague's** — check
  for a stray `.env` in a *sibling* repo. Those are read when that project
  runs standalone; the platform pins its own values (see
  [Configuration](#configuration-edit-env-here-not-in-a-sibling-repo)).
  `docker compose config` prints the fully-resolved settings actually in
  effect.

## Concepts, and where to read more

Every term below is something this platform actually uses — the "here"
column says where, so you can read the code alongside the theory. Links
are primary sources (official docs or the original paper), ordered
roughly easiest-first within each group.

### The language model itself

| Concept | Here | Read more |
| --- | --- | --- |
| **Large Language Model (LLM)** | `llama3.2:3b` — Meta's 3-billion-parameter model, ~2GB, running on your CPU | [Hugging Face LLM course](https://huggingface.co/learn/llm-course) |
| **Transformer** | The architecture every model here is built on | ["Attention Is All You Need"](https://arxiv.org/abs/1706.03762) (the 2017 paper that started it) |
| **Running models locally** | The `ollama` container | [Ollama](https://github.com/ollama/ollama) · [model library](https://ollama.com/library) |
| **Inference parameters** (temperature, context window) | `services/llm_inference.py` in `shopassist-service` | [Ollama model file reference](https://github.com/ollama/ollama/blob/main/docs/modelfile.md) |
| **Encoder vs decoder models** | Two *different* model families run side by side: `ollama` serves a decoder (generates text), `classifier` serves BERT-style encoders (score text) | [BERT paper](https://arxiv.org/abs/1810.04805) · [Transformers docs](https://huggingface.co/docs/transformers) |

### Making the model useful

| Concept | Here | Read more |
| --- | --- | --- |
| **Prompt engineering** | Every `call_*` method's prompt in `services/llm_inference.py` | [Anthropic prompt engineering guide](https://docs.claude.com/en/docs/build-with-claude/prompt-engineering/overview) |
| **Agents** | `services/agents/` — one specialist per job (orders, recommendations, general Q&A, escalation) | [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) |
| **Orchestration / routing** | `services/orchestrator.py` splits a message into sub-tasks and picks an agent for each | same article, "orchestrator-workers" section |
| **Tool use / function calling** | `OrderTrackingAgent` plans a call, then really queries Postgres | [Ollama tool support](https://ollama.com/blog/tool-support) |
| **RAG** (Retrieval-Augmented Generation) | `services/rag.py` — answers policy questions from the shipped PDFs instead of the model's memory | [Original RAG paper](https://arxiv.org/abs/2005.11401) |
| **Embeddings** | `nomic-embed-text` turns text into a 768-number vector so "refund" can match "money back" | [Getting started with embeddings](https://huggingface.co/blog/getting-started-with-embeddings) |
| **Vector search** | `document_chunks` in Postgres (pgvector), plus an in-process FAISS index | [pgvector](https://github.com/pgvector/pgvector) · [FAISS](https://faiss.ai/) |

### Doing it safely

| Concept | Here | Read more |
| --- | --- | --- |
| **PII masking** | `services/pii_masker.py` — strips emails/phones/addresses *before* the model sees them | [NIST guide to PII](https://csrc.nist.gov/pubs/sp/800/122/final) |
| **Prompt injection** | `GuardrailService.screen_input()` | [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/) |
| **Output filtering** | `GuardrailService.screen_output()` redacts anything PII-shaped in the reply | same OWASP list (LLM02, sensitive information disclosure) |
| **Evaluation** | `evaluation/` in `shopassist-service` — scores routing accuracy and retrieval quality | [RAGAS metrics](https://docs.ragas.io/) |
| **Tracing / observability for LLMs** | Langfuse hooks throughout (optional, off by default) | [Langfuse docs](https://langfuse.com/docs) |

### The plumbing around it

| Concept | Here | Read more |
| --- | --- | --- |
| **Containers & Compose** | Everything you just ran | [Docker Compose docs](https://docs.docker.com/compose/) |
| **REST API** | `shopassist-service`, and its interactive docs at `/docs` | [FastAPI](https://fastapi.tiangolo.com/) |
| **Web UI in pure Python** | `shopassist-client` | [Streamlit](https://docs.streamlit.io/) |
| **Relational database** | `shopassist-database` — customers, items, orders | [PostgreSQL tutorial](https://www.postgresql.org/docs/current/tutorial.html) |
| **Metrics dashboards** | The optional observability overlay above | [Prometheus](https://prometheus.io/docs/introduction/overview/) · [Grafana](https://grafana.com/docs/) |

### A suggested reading order through the code

1. `shopassist-client/app.py` — where a message is typed.
2. `shopassist-service/api/routers/chat.py` — where it arrives.
3. `shopassist-service/services/orchestrator.py` →
   `handle_customer_query()` — **the one method that runs everything**.
   Its numbered steps map 1:1 onto the pipeline described at the top of
   this README.
4. `shopassist-service/services/agents/order_tracking_agent.py` — the
   clearest example of an agent reasoning, calling a tool, then
   interpreting the result.
5. `shopassist-database/postgres/schema/schema.sql` — the data it all
   sits on.
