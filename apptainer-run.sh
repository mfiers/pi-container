#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# apptainer-run.sh — Launch the pi dev container via Apptainer / Singularity
#
# Uses a SANDBOX (plain directory) instead of a SIF file.
# This avoids squashfuse entirely — no FUSE required, works on any filesystem
# including NFS, GPFS, and Lustre (common on HPC clusters).
# The container root is mounted read-only (--no-write); your $HOME and CWD
# are bind-mounted read-write as usual.
#
# Key differences vs Docker:
#   - Runs as YOU automatically (no UID/GID remapping needed)
#   - $HOME is bind-mounted automatically (all dotfiles visible)
#   - Uses HOST network (no NAT; host Tailscale works transparently)
#   - No root daemon required — ideal for HPC clusters
#   - No squashfuse / FUSE needed — sandbox is a plain directory
#
# Tailscale note:
#   Do NOT run tailscaled inside the Apptainer container (needs NET_ADMIN).
#   Run Tailscale on the HOST instead — the container shares host networking.
#
# Usage:
#   apptainer-run.sh                     # interactive shell
#   apptainer-run.sh <command> [args]    # run a single command
#   apptainer-run.sh --pull              # (re)build the sandbox from registry
#   apptainer-run.sh --help
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults (overridable in config) ─────────────────────────────────────────
# Sandbox directory (plain directory tree, no squashfuse needed)
SANDBOX_DIR="${HOME}/.local/share/pi-container/pi-devcontainer"

# Docker Hub image to build from (same image as the Docker workflow)
REGISTRY_IMAGE="mfiers/pi-devcontainer:latest"

EXTRA_MOUNTS=()
EXTRA_ENV=()
EXTRA_APPTAINER_ARGS=()

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG_FILE="${HOME}/.config/pi-container/config.sh"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi
# Allow config to override sandbox location via APPTAINER_SANDBOX
SANDBOX_DIR="${APPTAINER_SANDBOX:-${SANDBOX_DIR}}"

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_PULL=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull|-p)   DO_PULL=true; shift ;;
        --help|-h)
            sed -n '3,24p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)  PASSTHROUGH_ARGS+=("$1"); shift ;;
    esac
done

# ── Prereq check ──────────────────────────────────────────────────────────────
if ! command -v apptainer &>/dev/null && ! command -v singularity &>/dev/null; then
    echo "✗ Neither 'apptainer' nor 'singularity' found on PATH."
    echo "  Install: https://apptainer.org/docs/admin/main/installation.html"
    exit 1
fi

# Prefer apptainer, fall back to singularity
APPTAINER_CMD="$(command -v apptainer 2>/dev/null || command -v singularity)"

# ── Build / update sandbox ────────────────────────────────────────────────────
if [[ "${DO_PULL}" == "true" ]] || [[ ! -d "${SANDBOX_DIR}/bin" ]]; then
    echo "Building sandbox from ${REGISTRY_IMAGE} → ${SANDBOX_DIR} ..."
    echo "(This takes a minute on first run; subsequent starts are instant)"

    # Build to a temp dir, validate, then move into place atomically.
    # A failed build never corrupts the live sandbox.
    TMP_SANDBOX="${SANDBOX_DIR}.tmp.$$"
    mkdir -p "$(dirname "${SANDBOX_DIR}")"

    build_sandbox() {
        # $1 — optional extra env vars, e.g. "GODEBUG=http2client=0"
        # --disable-cache: bypass Apptainer's OCI layer cache so stale/corrupt
        # cached layers can't produce a broken sandbox silently.
        env ${1:-} "${APPTAINER_CMD}" build \
            --sandbox \
            --disable-cache \
            --force \
            "${TMP_SANDBOX}" \
            "docker://${REGISTRY_IMAGE}"
    }

    validate_sandbox() {
        # Check that the sandbox has a working shell — catches partial builds
        "${APPTAINER_CMD}" exec --no-write "${TMP_SANDBOX}" true &>/dev/null
    }

    if build_sandbox && validate_sandbox; then
        rm -rf "${SANDBOX_DIR}"
        mv "${TMP_SANDBOX}" "${SANDBOX_DIR}"
    else
        rm -rf "${TMP_SANDBOX}"
        echo ""
        echo "⚠  Build failed — retrying with HTTP/2 disabled ..."
        echo "   (fixes \"stream ID N; PROTOCOL_ERROR\" on HPC networks/proxies)"
        if build_sandbox "GODEBUG=http2client=0" && validate_sandbox; then
            rm -rf "${SANDBOX_DIR}"
            mv "${TMP_SANDBOX}" "${SANDBOX_DIR}"
        else
            rm -rf "${TMP_SANDBOX}"
            echo "✗ Build failed. Check network access to Docker Hub and try again."
            exit 1
        fi
    fi

    echo "✓ Sandbox ready: ${SANDBOX_DIR}"
fi

if [[ ! -d "${SANDBOX_DIR}/bin" ]]; then
    echo "✗ Sandbox not found: ${SANDBOX_DIR}"
    echo "  Run with --pull to build it."
    exit 1
fi

# ── Current working directory ─────────────────────────────────────────────────
CWD="$(pwd)"

# ── Build bind-mount list ─────────────────────────────────────────────────────
# $HOME is mounted automatically by Apptainer — dotfiles need no explicit entry.
BINDS=()

# CWD at identical path so scripts with hardcoded paths work unchanged
BINDS+=(--bind "${CWD}:${CWD}")

# Extra mounts from config (bare path or "src:dst[:opts]")
for extra in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do
    if [[ "${extra}" != *:* ]]; then
        BINDS+=(--bind "${extra}:${extra}")
    else
        BINDS+=(--bind "${extra}")
    fi
done

# ── Environment ───────────────────────────────────────────────────────────────
ENV_ARGS=()
for env_var in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do
    ENV_ARGS+=(--env "${env_var}")
done

# Forward common API keys if already set in the shell
for key in ANTHROPIC_API_KEY OPENAI_API_KEY GITHUB_TOKEN HF_TOKEN REPLICATE_API_TOKEN; do
    [[ -n "${!key:-}" ]] && ENV_ARGS+=(--env "${key}=${!key}")
done

# ── Print summary ─────────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  pi-devcontainer (Apptainer)                            │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  User    : %-44s │\n" "$(id -un) ($(id -u):$(id -g))"
printf "│  CWD     : %-44s │\n" "${CWD}"
printf "│  Sandbox : %-44s │\n" "${SANDBOX_DIR##*/}"
echo "└─────────────────────────────────────────────────────────┘"

# ── Launch (--no-write keeps container root read-only) ───────────────────────
if [[ ${#PASSTHROUGH_ARGS[@]} -eq 0 ]]; then
    exec "${APPTAINER_CMD}" shell \
        --no-write \
        --workdir "${CWD}" \
        "${BINDS[@]}" \
        "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
        "${EXTRA_APPTAINER_ARGS[@]+"${EXTRA_APPTAINER_ARGS[@]}"}" \
        "${SANDBOX_DIR}"
else
    exec "${APPTAINER_CMD}" exec \
        --no-write \
        --workdir "${CWD}" \
        "${BINDS[@]}" \
        "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
        "${EXTRA_APPTAINER_ARGS[@]+"${EXTRA_APPTAINER_ARGS[@]}"}" \
        "${SANDBOX_DIR}" \
        "${PASSTHROUGH_ARGS[@]}"
fi
