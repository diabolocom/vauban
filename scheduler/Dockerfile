FROM python:3.13-slim AS base

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

WORKDIR /srv

RUN apt-get update && \
    apt-get install -y --no-install-recommends python-dev-is-python3 curl

COPY pyproject.toml poetry.lock ./

RUN pip3 install poetry && \
    poetry install --only main --no-root && rm -rf $POETRY_CACHE_DIR

# FIXME allow config
FROM zarakailloux/vauban-client:latest AS vauban-client

FROM base

WORKDIR /srv

ENV VIRTUAL_ENV=/srv/.venv \
    PATH="/srv/.venv/bin:$PATH" \
    CHECK_FOR_UPGRADE=no \
    HOME=/app

COPY --from=builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}
COPY --from=vauban-client /usr/local/bin/vauban-client /usr/local/bin/vauban-client

RUN useradd -d "$HOME" -r -u 1000 app && \
    mkdir -p "$HOME"/.config && \
    chown app:1000 -R "$HOME" && \
    apt-get update && \
    apt-get install -y curl git jo jq

USER app:1000

COPY ./ ./

ENTRYPOINT ["python", "scheduler"]
