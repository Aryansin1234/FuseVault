FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y \
    libfuse-dev \
    fuse \
    openssl \
    libssl-dev \
    pkg-config \
    gcc \
    build-essential \
    argon2 \
    cppcheck \
    clang-format \
    inotify-tools \
    rsync \
    xxd \
    curl \
    tar \
    locales \
    && locale-gen C.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# ── Install gum (Charm TUI toolkit) ──────────────────────────────────────────
# Charm release tarballs use "Linux" (capital L) and "x86_64" (not "amd64").
# The binary lives inside a subdirectory, so we extract to a temp dir and
# use find to locate it — robust across tarball layouts.
RUN set -eux; \
    GUM_VERSION="0.14.5"; \
    ARCH="$(uname -m)"; \
    case "$ARCH" in \
        x86_64)  GUM_ARCH="x86_64" ;; \
        aarch64) GUM_ARCH="arm64"  ;; \
        armv7l)  GUM_ARCH="armv7"  ;; \
        *)       echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac; \
    GUM_URL="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"; \
    mkdir -p /tmp/gum-install; \
    curl -fsSL "$GUM_URL" -o /tmp/gum.tar.gz; \
    tar xzf /tmp/gum.tar.gz -C /tmp/gum-install; \
    find /tmp/gum-install -type f -name 'gum' -exec install -m 755 {} /usr/local/bin/gum \;; \
    rm -rf /tmp/gum.tar.gz /tmp/gum-install; \
    gum --version

WORKDIR /workspace

# To run FuseVault, use:
#   docker run -it --privileged --cap-add SYS_ADMIN --device /dev/fuse \
#     --name fusevault -v $(pwd):/workspace fusevault bash
