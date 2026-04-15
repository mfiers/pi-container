# syntax=docker/dockerfile:1
# ────────────────────────────────────────────────────────────────────────────
# pi-devcontainer — Secure AI development environment
# rapidsai/base (Ubuntu 24.04) · CUDA 12.8 · PyTorch 2.7 · RAPIDS 25.02
# uv · micromamba · tailscale
# ────────────────────────────────────────────────────────────────────────────
FROM rapidsai/base:25.02-cuda12.8-py3.11

# rapidsai/base runs as non-root — switch to root for all setup
USER root

# /opt/conda is group-restricted (group: conda, mode 770) — open to all users
# so any UID injected at runtime by the entrypoint can use Python/CUDA tools
RUN chmod -R a+rX /opt/conda

LABEL org.opencontainers.image.title="pi-devcontainer"
LABEL org.opencontainers.image.description="Secure AI dev container: uv, micromamba, tailscale, CUDA 12.8, RAPIDS 25.02"
LABEL org.opencontainers.image.base.name="rapidsai/base:25.02-cuda12.8-py3.11"

# ── Environment ───────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ── Base system packages ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core
    bash \
    ca-certificates \
    curl \
    wget \
    git \
    gnupg \
    lsb-release \
    # Process / signal management
    tini \
    gosu \
    procps \
    # Shell productivity
    tmux \
    vim-tiny \
    less \
    jq \
    fzf \
    # SSH
    openssh-client \
    # Network / debug
    iproute2 \
    iputils-ping \
    dnsutils \
    netcat-openbsd \
    # Build tools (needed by some Python packages via uv)
    build-essential \
    pkg-config \
    # Misc
    sudo \
    rsync \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# ── Tailscale ─────────────────────────────────────────────────────────────────
# Official Tailscale Ubuntu Noble repo (handles amd64 + arm64 automatically)
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/tailscale /var/lib/tailscale

# ── uv (Python toolchain) ─────────────────────────────────────────────────────
# Install to /usr/local/bin so it's on PATH for all users
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv --version

# ── micromamba ────────────────────────────────────────────────────────────────
# Standalone binary: no base Python needed, full conda compatibility
# TARGETARCH is set automatically by Docker BuildKit
ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
        amd64)   MAMBA_ARCH="linux-64"       ;; \
        arm64)   MAMBA_ARCH="linux-aarch64"  ;; \
        *)       echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -Ls "https://micro.mamba.pm/api/micromamba/${MAMBA_ARCH}/latest" \
        | tar -xvj -C /usr/local/bin/ --strip-components=1 bin/micromamba \
    && chmod +x /usr/local/bin/micromamba \
    && micromamba --version

# ── micromamba: system-wide shell hook ───────────────────────────────────────
# Placed in /etc/profile.d so it activates for ALL users without touching
# the user's .bashrc (which may be mounted read-only from the host).
RUN cat > /etc/profile.d/micromamba.sh << 'EOF'
# micromamba shell hook — sourced for all login/interactive shells
export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-${HOME}/.mamba}"
export MAMBA_EXE=/usr/local/bin/micromamba
eval "$($MAMBA_EXE shell hook -s bash 2>/dev/null)"
EOF

# ── Container-specific environment overrides ─────────────────────────────────
RUN cat > /etc/profile.d/container-env.sh << 'EOF'
# Useful defaults inside the container
export EDITOR="${EDITOR:-vim}"
export PAGER="${PAGER:-less}"
# uv cache: per-user under HOME so it persists across sessions if HOME is mounted
export UV_CACHE_DIR="${HOME}/.cache/uv"
# pip respects NO_COLOR etc; uv does too
export PYTHONDONTWRITEBYTECODE=1
EOF

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# tini as PID 1: proper signal handling + zombie reaping
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash", "-l"]
