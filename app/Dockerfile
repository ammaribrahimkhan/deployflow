FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install only production dependencies (better layer caching, smaller image)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Release metadata baked in at build time
ARG APP_VERSION=dev
ARG GIT_SHA=local
ENV APP_VERSION=$APP_VERSION \
    GIT_SHA=$GIT_SHA

# Run as a non-root user
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health', timeout=3)"]

CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "2", "main:app"]