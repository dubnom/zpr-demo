ARG RUNTIME_BASE=ubuntu:24.04
FROM ubuntu:24.04 AS redis-runtime
RUN apt-get update && apt-get install -y --no-install-recommends redis-server \
 && rm -rf /var/lib/apt/lists/*

FROM ${RUNTIME_BASE}

# ZPR runtime deps + Redis protocol-compatible local state store, tmux, nginx,
# figlet (web1's live banner page), and TUN tooling.
RUN apt-get update && apt-get install -y \
    tmux \
    nginx \
    figlet \
    libjemalloc2 \
    liblzf1 \
    procps \
    iproute2 \
    ca-certificates \
    libpcap-dev \
    curl \
    socat \
    build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=redis-runtime /usr/bin/redis-server /usr/bin/redis-cli \
    /usr/bin/redis-check-rdb /usr/bin/redis-check-aof /usr/local/bin/

# Bake in the ZPR binaries (local only, no registry push — plan §5/Image).
ARG BIN_DIR=bin
COPY ${BIN_DIR}/ /app/bin/
