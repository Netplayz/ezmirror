ARG DEBIAN_VERSION=bookworm

# Stage 1: Build the Rust daemon
FROM rust:${DEBIAN_VERSION} AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release 2>/dev/null || true
COPY src/ src/
RUN cargo build --release && \
    cp target/release/ezmirord /tmp/ezmirord && \
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
        python3-pip \
        ca-certificates \
    && \
    pip3 install -q --break-system-packages fastapi uvicorn && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/nginx/sites-enabled/default

COPY --from=builder /tmp/ezmirord /usr/local/sbin/ezmirord
COPY mirrors.json /opt/ezmirror/mirrors.json
COPY templates/ /opt/ezmirror/templates/
COPY python/ /opt/ezmirror/python/
COPY web/ /opt/ezmirror/web/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod +x /usr/local/sbin/ezmirord /usr/local/bin/docker-entrypoint.sh /opt/ezmirror/web/panel.py && \
    mkdir -p /etc/ezmirror /var/www/html /var/log /var/run

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -sf http://127.0.0.1:9633/healthz || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
