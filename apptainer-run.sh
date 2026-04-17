#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# apptainer-run.sh — Launch the pi dev container via Apptainer / Singularity
#
# Key differences vs Docker:
#   - Runs as YOU automatically (no UID/GID remapping needed)
#   - $HOME is bind-mounted automatically (all dotfiles visible without
#     explicit mounts)
#   - Uses HOST network by default (no NAT, Tailscale on the host just works)
#   - No root daemon required — ideal for HPC clusters
#   - Images are .sif files stored locally
#
# Tailscale note:
#   Do NOT run tailscaled inside the Apptainer container (needs NET_ADMIN).
#   Instead, run Tailscale on the HOST — the container sees the host network
#   and uses the VPN transparently.  On HPC clusters you typically don't need
#   a VPN at all.
#
# Usage:
#   apptainer-run.sh                     # interactive shell
#   apptainer-run.sh <command> [args]    # run a single command
#   apptainer-run.sh --pull              # re-pull / update the SIF image
#   apptainer-run.sh --help
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults (overridable in config) ─────────────────────────────────────────
# Where to store the .sif image (defaults to ~/.local/share/pi-container/)
SIF_DIR="${HOME}/.local/share/pi-container"
SIF_IMAGE="${SIF_DIR}/pi-devcontainer.sif"

# Docker Hub image to pull from (same image as the Docker workflow)
REGISTRY_IMAGE="mfiers/pi-devcontainer:latest"

EXTRA_MOUNTS=()
EXTRA_ENV=()
EXTRA_APPTAINER_ARGS=()

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HOME}/.config/pi-container/config.sh"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi
# Allow config to override SIF location via APPTAINER_SIF
SIF_IMAGE="${APPTAINER_SIF:-${SIF_IMAGE}}"
SIF_DIR="$(dirname "${SIF_IMAGE}")"

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_PULL=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull|-p)   DO_PULL=true; shift ;;
        --help|-h)
            sed -n '3,23p' "$0" | sed 's/^# \?//'
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

# ── Pull / update SIF ─────────────────────────────────────────────────────────
mkdir -p "${SIF_DIR}"

if [[ "${DO_PULL}" == "true" ]] || [[ ! -f "${SIF_IMAGE}" ]]; then
    echo "Pulling ${REGISTRY_IMAGE} → ${SIF_IMAGE} ..."

    # Pull to a temp file so a failed/partial download never sits at the real
    # path (a corrupt SIF at SIF_IMAGE causes a cryptic "image format not
    # recognised" error on the next run even though pull printed ✓).
    TMP_SIF="${SIF_IMAGE}.tmp.$$"

    pull_sif() {
        # $1 — optional env prefix, e.g. "GODEBUG=http2client=0"
        env ${1:-} "${APPTAINER_CMD}" pull --force "${TMP_SIF}" "docker://${REGISTRY_IMAGE}"
    }

    validate_sif() {
        "${APPTAINER_CMD}" inspect "${TMP_SIF}" &>/dev/null
    }

    # First attempt: normal (HTTP/2 enabled)
    if pull_sif && validate_sif; then
        mv -f "${TMP_SIF}" "${SIF_IMAGE}"
    else
        # Remove any partial file from the first attempt before retrying
        rm -f "${TMP_SIF}"
        echo ""
        echo "⚠  Pull failed or SIF invalid — retrying with HTTP/2 disabled ..."
        echo "   (fixes \"stream ID N; PROTOCOL_ERROR\" on HPC networks/proxies)"
        if pull_sif "GODEBUG=http2client=0" && validate_sif; then
            mv -f "${TMP_SIF}" "${SIF_IMAGE}"
        else
            rm -f "${TMP_SIF}"
            echo "✗ Pull failed.  Check network access to Docker Hub and try again."
            exit 1
        fi
    fi

    echo "✓ SIF ready: ${SIF_IMAGE}"
fi

if [[ ! -f "${SIF_IMAGE}" ]]; then
    echo "✗ SIF not found: ${SIF_IMAGE}"
    echo "  Run with --pull to download it."
    exit 1
fi

# ── Current working directory ─────────────────────────────────────────────────
CWD="$(pwd)"

# ── Build bind-mount list ─────────────────────────────────────────────────────
# NOTE: $HOME is mounted automatically by Apptainer — no need to list dotfiles.
BINDS=()

# CWD at same path (Apptainer makes CWD accessible but doesn't guarantee path)
BINDS+=(--bind "${CWD}:${CWD}")

# Extra mounts from config (same format as Docker: "src:dst" or bare "path")
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

# Forward common API keys if set in the shell
for key in ANTHROPIC_API_KEY OPENAI_API_KEY GITHUB_TOKEN HF_TOKEN REPLICATE_API_TOKEN; do
    [[ -n "${!key:-}" ]] && ENV_ARGS+=(--env "${key}=${!key}")
done

# ── Print summary ─────────────────────────────────────────────────────────────
echo "┌─────────────────────────────────────────────────────────┐"
echo "│  pi-devcontainer (Apptainer)                            │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  User   : %-45s │\n" "$(id -un) ($(id -u):$(id -g))"
printf "│  CWD    : %-45s │\n" "${CWD}"
printf "│  SIF    : %-45s │\n" "${SIF_IMAGE##*/}"
echo "└─────────────────────────────────────────────────────────┘"

# ── Launch ────────────────────────────────────────────────────────────────────
if [[ ${#PASSTHROUGH_ARGS[@]} -eq 0 ]]; then
    # Interactive shell
    exec "${APPTAINER_CMD}" shell \
        --workdir "${CWD}" \
        "${BINDS[@]}" \
        "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
        "${EXTRA_APPTAINER_ARGS[@]+"${EXTRA_APPTAINER_ARGS[@]}"}" \
        "${SIF_IMAGE}"
else
    # Run a specific command
    exec "${APPTAINER_CMD}" exec \
        --workdir "${CWD}" \
        "${BINDS[@]}" \
        "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
        "${EXTRA_APPTAINER_ARGS[@]+"${EXTRA_APPTAINER_ARGS[@]}"}" \
        "${SIF_IMAGE}" \
        "${PASSTHROUGH_ARGS[@]}"
fi
