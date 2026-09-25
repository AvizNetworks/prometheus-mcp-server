# Shared hardened NCP base (see deploy-ones/dockerfiles/ncp-python-base-312-alpine).
# Every dependency ships a musllinux wheel; Alpine drops the Debian OS findings.
ARG PYTHON_BASE=avizdock/ncp-python-base-312-alpine:latest
# Runtime stage: plain upstream python:3.12-alpine -- the same Alpine release and
# CPython the shared base is built FROM, but without its build toolchain, so the
# image does not carry ~450 MB of gcc/binutils/git layers underneath. Override
# with a lean shared runtime base once deploy-ones provides one.
ARG PYTHON_RUNTIME_BASE=python:3.12-alpine

FROM ${PYTHON_BASE} AS builder

RUN pip install --no-cache-dir uv

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY pyproject.toml ./
COPY uv.lock ./

COPY src ./src/

# uv sync installs the project itself (editable, pointing at /app/src). No pip or
# setuptools goes into the venv — they are not needed at runtime.
RUN uv venv && \
    uv sync --frozen --no-dev

# --- runtime: lean upstream alpine (PYTHON_RUNTIME_BASE), no toolchain or pip ---
FROM ${PYTHON_RUNTIME_BASE}

WORKDIR /app

# Build toolchain, packaging tools: if PYTHON_RUNTIME_BASE is the shared alpine base it
# carries build-base/git/curl/*-dev, and every base carries pip/setuptools/wheel
# for building; none are needed at runtime (the healthcheck uses python, and
# busybox provides pgrep), and they are the bulk of the image's HIGH findings.
RUN pkgs="$(apk info -e build-base libffi-dev openssl-dev git curl || true)" \
    && if [ -n "$pkgs" ]; then apk del --no-cache $pkgs; fi \
    && apk upgrade --no-cache \
    && apk add --no-cache ca-certificates \
    && (python -m pip uninstall -y setuptools wheel pip || true) \
    && (id app >/dev/null 2>&1 || (addgroup -g 10001 app && adduser -D -u 10001 -G app app)) \
    && chown -R app:app /app && \
    chmod 755 /app && \
    chmod -R go-w /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --from=builder --chown=app:app /app/src /app/src
COPY --chown=app:app pyproject.toml /app/

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="/app" \
    PYTHONFAULTHANDLER=1 \
    PROMETHEUS_MCP_BIND_HOST=0.0.0.0 \
    PROMETHEUS_MCP_BIND_PORT=8080 \
    PROMETHEUS_MCP_SERVER_TRANSPORT=sse

USER app

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD if [ "$PROMETHEUS_MCP_SERVER_TRANSPORT" = "http" ] || [ "$PROMETHEUS_MCP_SERVER_TRANSPORT" = "sse" ]; then \
            python -c "import os,urllib.request; urllib.request.urlopen('http://localhost:%s/health' % os.environ['PROMETHEUS_MCP_BIND_PORT'], timeout=5)" >/dev/null 2>&1 || exit 1; \
        else \
            pgrep -f prometheus-mcp-server >/dev/null 2>&1 || exit 1; \
        fi

CMD ["/app/.venv/bin/prometheus-mcp-server"]
