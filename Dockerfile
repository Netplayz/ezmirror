ARG DEBIAN_VERSION=bookworm

# Stage 1: Build the C daemon
FROM debian:${DEBIAN_VERSION} AS builder

RUN apt-get update -qq && \
    apt-get install -y -qq gcc libc6-dev 2>/dev/null && \
    rm -rf /var/lib/apt/lists/*

COPY src/ /tmp/src/
RUN gcc -O2 -Wall -pthread \
    -o /tmp/ezmirord \
    /tmp/src/main.c \
    /tmp/src/config.c \
    /tmp/src/sync.c \
    /tmp/src/status.c \
    /tmp/src/metrics.c && \
    strip /tmp/ezmirord

# Stage 2: Runtime image
FROM debian:${DEBIAN_VERSION}-slim

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        nginx \
        nginx-extras \
        rsync \
        jq \
        curl \
        moreutils \
        python3 \
        ca-certificates \
    && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/default

COPY --from=builder /tmp/ezmirord /usr/local/sbin/ezmirord
COPY mirrors.json /opt/ezmirror/mirrors.json
COPY templates/ /opt/ezmirror/templates/
COPY python/ /opt/ezmirror/python/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/sbin/ezmirord /usr/local/bin/docker-entrypoint.sh && \
    mkdir -p /etc/ezmirror /var/www/html /var/log /var/run

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -sf http://127.0.0.1:9633/healthz || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
