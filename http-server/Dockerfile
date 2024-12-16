FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    DEV=0 \
    PYTHONDONTWRITEBYTECODE=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    POETRY_CACHE_DIR=/tmp/poetry_cache

FROM base AS builder

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends python-dev-is-python3 curl

COPY pyproject.toml poetry.lock ./

RUN pip3 install poetry && \
    poetry install --only main --no-root && rm -rf $POETRY_CACHE_DIR

FROM base

WORKDIR /app

ENV VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

RUN useradd -d /app -r -u 1000 app && \
    mkdir -p /git /config /db /tmp && \
    chown app:1000 -R /app /git /config /db /tmp

USER app:1000

COPY ./ ./

HEALTHCHECK --interval=10s --timeout=3s CMD curl -f localhost:5000/readiness || exit 1

EXPOSE 5000

ENTRYPOINT ["flask", "--app", "vauban-http-server", "run", "--host", "::", "--debug"]
