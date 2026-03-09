FROM debian:stable-slim@sha256:85dfcffff3c1e193877f143d05eaba8ae7f3f95cb0a32e0bc04a448077e1ac69

ARG TARGETARCH
ARG TARGETVARIANT
ARG EARNAPP_VERSION=""

ENV DEBIAN_FRONTEND=noninteractive
ENV APP_DIR=/app/src/
ENV BIN_PATH=/usr/bin/earnapp
ENV CONFIG_DIR=/etc/earnapp
ENV INSTALLER_URL=https://brightdata.com/static/earnapp/install.sh
ENV CDN_BASE=https://cdn-earnapp.b-cdn.net/static
ENV MALLOC_ARENA_MAX=2

# Install deps, download binary, compile idle helper, then purge build tools
# Runtime deps (iptables, redsocks) are kept for optional SOCKS5 proxy support
COPY src/idle.c /tmp/idle.c
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl ca-certificates gcc libc6-dev unzip \
        iptables redsocks iproute2 procps \
    && mkdir -p $APP_DIR $CONFIG_DIR \
    && if [ -z "$EARNAPP_VERSION" ]; then \
        export EARNAPP_VERSION=$(curl -fsSL $INSTALLER_URL | grep VERSION= | cut -d'"' -f2); \
    fi \
    && echo "[INFO] Installing EarnApp version $EARNAPP_VERSION for arch $TARGETARCH/$TARGETVARIANT" \
    && case "$TARGETARCH" in \
        amd64) FILE="earnapp-x64-$EARNAPP_VERSION" ;; \
        arm64) FILE="earnapp-aarch64-$EARNAPP_VERSION" ;; \
        arm) \
            case "$TARGETVARIANT" in \
                v7|v6) FILE="earnapp-arm7l-$EARNAPP_VERSION" ;; \
                *) echo "[ERROR] Unsupported ARM variant: $TARGETVARIANT"; exit 1 ;; \
            esac ;; \
        *) echo "[ERROR] Unsupported architecture: $TARGETARCH"; exit 1 ;; \
    esac \
    && curl -fL "$CDN_BASE/$FILE" -o "$BIN_PATH" \
    && chmod +x "$BIN_PATH" \
    && echo "[INFO] EarnApp binary downloaded." \
    && XRAY_VERSION=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') \
    && if [ -z "$XRAY_VERSION" ]; then echo "[ERROR] Failed to fetch Xray version from GitHub API"; exit 1; fi \
    && echo "[INFO] Installing Xray version $XRAY_VERSION" \
    && case "$TARGETARCH" in \
        amd64) XRAY_FILE="Xray-linux-64.zip" ;; \
        arm64) XRAY_FILE="Xray-linux-arm64-v8a.zip" ;; \
        arm) XRAY_FILE="Xray-linux-arm32-v7a.zip" ;; \
    esac \
    && curl -fL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_FILE}" -o /tmp/xray.zip \
    && unzip -o /tmp/xray.zip xray -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm /tmp/xray.zip \
    && gcc -O2 -s -o /usr/local/bin/_idle /tmp/idle.c \
    && rm /tmp/idle.c \
    && apt-get purge -y --auto-remove curl ca-certificates gcc libc6-dev unzip \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Fake hostnamectl for EarnApp
RUN echo -e '#!/bin/sh\nhostname' > /usr/bin/hostnamectl && chmod +x /usr/bin/hostnamectl

# Fake lsb_release for EarnApp
RUN echo -e '#!/bin/sh\necho "Distributor ID: Debian"\necho "Description: Debian Bookworm"\necho "Release: 12"\necho "Codename: bookworm"' \
    > /usr/bin/lsb_release && chmod +x /usr/bin/lsb_release

# Fake systemd presence (earnapp scans /proc for system services)
RUN mkdir -p /run/systemd/system

# Copy entrypoint, loop, and monitor scripts
COPY src/entrypoint.sh /entrypoint.sh
COPY src/earnapp_loop.sh /usr/local/bin/_earnapp_loop
COPY src/ip_monitor.sh /usr/local/bin/_ip_monitor
RUN chmod +x /entrypoint.sh /usr/local/bin/_earnapp_loop /usr/local/bin/_ip_monitor

HEALTHCHECK --interval=1m --timeout=10s --start-period=10s --retries=2 CMD cat /etc/earnapp/status | grep enabled && exit 0 || exit 1
# Persistent configuration
VOLUME ["/etc/earnapp"]

# Entrypoint
ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]