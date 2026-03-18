# Backlog ID Server - Production Dockerfile
# Multi-stage build for minimal runtime image

# Build stage
FROM erlang:28-alpine AS builder

RUN apk add --no-cache git build-base

WORKDIR /app

# Copy rebar config first for dep caching
COPY rebar.config rebar.lock* ./

RUN rebar3 deps

# Copy full source
COPY src/ src/
COPY config/ config/

# Compile and build release
RUN rebar3 as prod release

# Runtime stage
FROM erlang:28-alpine

RUN apk add --no-cache libstdc++ ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/backlog_server ./

EXPOSE 8090

ENV BACKLOG_PORT=8090
ENV BACKLOG_DATA_DIR=/data

CMD ["bin/backlog_server", "foreground"]
