FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Retries and a longer timeout help on an unreliable network.
COPY requirements.txt .
RUN pip install --no-cache-dir --retries 5 --timeout 100 -r requirements.txt

COPY config.py azure_api.py analysis.py main.py ./
COPY web ./web

ARG APP_VERSION=dev
ARG GIT_SHA=local
ENV APP_VERSION=$APP_VERSION \
    GIT_SHA=$GIT_SHA

RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/healthz', timeout=3)"]

# One worker with several threads: the dashboard keeps its short-lived cache in memory.
CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "1", "--threads", "8", "--timeout", "120", "main:app"]