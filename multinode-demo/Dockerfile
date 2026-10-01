FROM ubuntu:24.04

# ZPR runtime deps + tmux (log sessions) + nginx/figlet (web1's live banner page)
# + tun tooling.
RUN apt-get update && apt-get install -y \
    tmux \
    nginx \
    figlet \
    iproute2 \
    ca-certificates \
    libpcap-dev \
    curl \
    wget \
    socat \
    build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# valkey (vs needs it on 127.0.0.1:6379) — not in 24.04's default repos, build from source.
ARG VALKEY_VERSION=7.2.11
RUN wget -O "valkey-${VALKEY_VERSION}.tar.gz" "https://github.com/valkey-io/valkey/archive/refs/tags/${VALKEY_VERSION}.tar.gz" \
 && tar xf "valkey-${VALKEY_VERSION}.tar.gz" \
 && cd "valkey-${VALKEY_VERSION}" \
 && make && make install \
 && cd /app \
 && rm -rf "valkey-${VALKEY_VERSION}" "valkey-${VALKEY_VERSION}.tar.gz"

# Bake in the ZPR binaries (local only, no registry push — plan §5/Image).
COPY bin/ /app/bin/
