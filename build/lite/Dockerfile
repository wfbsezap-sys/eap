FROM debian:stable-slim

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
COPY src/idle.c /tmp/idle.c
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl ca-certificates gcc libc6-dev \
        tini iproute2 procps \
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
    && gcc -O2 -s -o /usr/local/bin/_idle /tmp/idle.c \
    && rm /tmp/idle.c \
    && apt-get purge -y --auto-remove gcc libc6-dev \
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

HEALTHCHECK --interval=1m --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -x earnapp > /dev/null && \
        test "$(cat /etc/earnapp/status 2>/dev/null)" != "" || exit 1

# Persistent configuration
VOLUME ["/etc/earnapp"]

# Use tini as PID 1 for proper signal handling and zombie reaping
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/entrypoint.sh"]
CMD ["run"]
