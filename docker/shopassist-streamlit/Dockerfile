# Builds the shopassist-streamlit storefront image.
#
# Same rationale as ../shopassist/Dockerfile: built FROM shopassist-devops
# with `context: ../shopassist-streamlit` (see ../../docker-compose.yml),
# so that repo stays free of Docker/infra files. COPY lines are explicit
# so the image never picks up .venv/, .git/, .env, or logs/ from that
# working tree.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py config.py config.yaml ./
COPY chatbot ./chatbot
COPY components ./components
COPY pages ./pages
COPY utils ./utils
COPY data ./data
COPY styles ./styles
COPY assets ./assets
COPY .streamlit ./.streamlit

EXPOSE 8501

# mock_gateway.py is intentionally not copied in — this container always
# talks to the real, containerized shopassist API (see API_BASE_URL in
# ../../docker-compose.yml), so the local stdlib mock has nothing to do.
CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8501", "--server.headless=true"]
