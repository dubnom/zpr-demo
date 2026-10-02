FROM ubuntu:24.04

# ZPR runtime deps + Redis protocol-compatible local state store, tmux, nginx,
# figlet (web1's live banner page), and TUN tooling.
RUN apt-get update && apt-get install -y \
    tmux \
    nginx \
    figlet \
    redis-server \
    iproute2 \
    ca-certificates \
    libpcap-dev \
    curl \
    socat \
    build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Bake in the ZPR binaries (local only, no registry push — plan §5/Image).
COPY bin/ /app/bin/
