# Builds the shopassist FastAPI backend image.
#
# Deliberately built FROM the shopassist-devops repo, not from a Dockerfile
# living inside shopassist itself — that project stays pure application
# logic, with zero Docker/infra concerns in it. This file is invoked with
# `context: ../shopassist` (see ../../docker-compose.yml), so every COPY
# below reaches into that sibling checkout.
#
# COPY lines are explicit (no `COPY . .`) on purpose: shopassist's working
# tree has a local .venv/, .git/, .env, .env.production, and a generated
# db/shopassist.db sitting in it that have no business inside an image
# layer. Naming exactly what's needed is what actually keeps them out,
# since a .dockerignore placed here wouldn't apply to a context directory
# in a different repo.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY api ./api
COPY common ./common
COPY services ./services
COPY db ./db

EXPOSE 8000

# Rebuilds db/shopassist.db from schema + seed data fresh on every container
# start — cheap, and gives every demo run the same known dataset. Only
# matters when DATABASE_URL isn't set (the SQLite fallback path); harmless
# no-op work otherwise.
CMD ["sh", "-c", "python db/init_db.py && uvicorn api.main:app --host 0.0.0.0 --port 8000"]
