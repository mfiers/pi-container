#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# entrypoint.sh  — runs as root, then drops to the host user
#
# Responsibilities:
#   1. Create matching UID/GID inside the container
#   2. Ensure home-dir skeleton exists (for unmounted sub-paths)
#   3. Start tailscaled daemon (if enabled)
#   4. Drop privileges to the host user via gosu
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Identity from the run script ─────────────────────────────────────────────
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
HOST_USER="${HOST_USER:-devuser}"
HOST_HOME="${HOST_HOME:-/home/${HOST_USER}}"
ENABLE_TAILSCALE="${ENABLE_TAILSCALE:-true}"

# ── Create group ──────────────────────────────────────────────────────────────
if ! getent group "${HOST_GID}" >/dev/null 2>&1; then
    groupadd -g "${HOST_GID}" "${HOST_USER}" 2>/dev/null \
        || groupadd -g "${HOST_GID}" "grp${HOST_GID}"
fi
GROUP_NAME=$(getent group "${HOST_GID}" | cut -d: -f1)

# ── Create user ───────────────────────────────────────────────────────────────
if ! getent passwd "${HOST_UID}" >/dev/null 2>&1; then
    useradd \
        --uid  "${HOST_UID}" \
        --gid  "${HOST_GID}" \
        --home "${HOST_HOME}" \
        --shell /bin/bash \
        --no-create-home \
        "${HOST_USER}" 2>/dev/null \
        || useradd \
            --uid  "${HOST_UID}" \
            --gid  "${HOST_GID}" \
            --home "${HOST_HOME}" \
            --shell /bin/bash \
            --no-create-home \
            "usr${HOST_UID}"
fi
REAL_USER=$(getent passwd "${HOST_UID}" | cut -d: -f1)

# ── Home-directory skeleton ───────────────────────────────────────────────────
# The host's real home dirs are bind-mounted, but Docker may not have created
# every intermediate directory.  We just need the tree to exist.
mkdir -p "${HOST_HOME}"
# Only chown if we actually own it (avoids NFS / squash errors)
chown "${HOST_UID}:${HOST_GID}" "${HOST_HOME}" 2>/dev/null || true

# Common cache/runtime dirs the user might expect
for d in \
    "${HOST_HOME}/.cache" \
    "${HOST_HOME}/.local/bin" \
    "${HOST_HOME}/.local/share" \
    "${HOST_HOME}/.mamba" \
    "${HOST_HOME}/.config"; do
    mkdir -p "$d" 2>/dev/null || true
    chown "${HOST_UID}:${HOST_GID}" "$d" 2>/dev/null || true
done

# ── Tailscale ─────────────────────────────────────────────────────────────────
if [[ "${ENABLE_TAILSCALE}" == "true" ]]; then
    mkdir -p /var/run/tailscale /var/lib/tailscale

    if ! pgrep -x tailscaled >/dev/null 2>&1; then
        # Use kernel TUN if /dev/net/tun is available, otherwise userspace
        if [[ -c /dev/net/tun ]]; then
            tailscaled \
                --state=/var/lib/tailscale/tailscaled.state \
                --socket=/var/run/tailscale/tailscaled.sock \
                2>/var/log/tailscaled.log &
        else
            echo "⚠ /dev/net/tun not available — using Tailscale userspace networking"
            tailscaled \
                --state=/var/lib/tailscale/tailscaled.state \
                --socket=/var/run/tailscale/tailscaled.sock \
                --tun=userspace-networking \
                2>/var/log/tailscaled.log &
        fi

        # Give the daemon a moment to start
        sleep 1
    fi

    # Status check (non-fatal)
    if tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        echo "✓ Tailscale connected (${TS_IP})"
    else
        echo "⚠  Tailscale not yet authenticated."
        echo "   Run inside the container: tailscale up"
        echo "   State is persisted — you only need to do this once."
    fi
fi

# ── Drop to host user ─────────────────────────────────────────────────────────
echo "→ Entering container as ${REAL_USER} (${HOST_UID}:${HOST_GID})"
exec gosu "${HOST_UID}" "$@"
