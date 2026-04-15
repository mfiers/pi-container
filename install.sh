#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# install.sh — Install pi-container on this machine
#
# Modes
# ─────
#  Local build   (default, needs the full repo):
#    ./install.sh
#
#  Pull pre-built image from a registry (only run.sh needed after):
#    ./install.sh --from-registry yourname/pi-devcontainer:latest
#
#  Non-interactive (CI / remote bootstrap via curl | bash):
#    REGISTRY=yourname/pi-devcontainer:latest \
#      bash <(curl -fsSL https://raw.githubusercontent.com/mfiers/pi-container/main/install.sh)
#
# What is installed
# ─────────────────
#  ~/.config/pi-container/config.sh   user config (created once, never overwritten)
#  ~/.local/bin/pirun                 self-contained launcher (no SCRIPT_DIR dep)
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/pi-container"
CONFIG_FILE="${CONFIG_DIR}/config.sh"
PIRUN="${BIN_DIR}/pirun"

# ── Defaults ──────────────────────────────────────────────────────────────────
REGISTRY="${REGISTRY:-}"        # set via env or --from-registry flag
IMAGE_NAME="pi-devcontainer:latest"
DO_BUILD=true

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-registry|-r)
            REGISTRY="$2"
            DO_BUILD=false
            shift 2 ;;
        --no-build)
            DO_BUILD=false
            shift ;;
        --help|-h)
            sed -n '3,20p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)  echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# If a REGISTRY was given via env and no --from-registry flag, honour it
[[ -n "${REGISTRY}" ]] && DO_BUILD=false

echo "╔══════════════════════════════════════╗"
echo "║     pi-devcontainer  install         ║"
echo "╚══════════════════════════════════════╝"

# ── Prereq check ──────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "✗ Docker not found.  Install it first:"
    echo "  https://docs.docker.com/engine/install/"
    exit 1
fi
echo "✓ Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ── Config ────────────────────────────────────────────────────────────────────
mkdir -p "${CONFIG_DIR}"
if [[ ! -f "${CONFIG_FILE}" ]]; then
    # Fetch config template: from local copy or from raw GitHub URL
    if [[ -f "${SCRIPT_DIR}/config.example.sh" ]]; then
        cp "${SCRIPT_DIR}/config.example.sh" "${CONFIG_FILE}"
    elif [[ -n "${REGISTRY}" ]]; then
        # Derive a raw URL guess from the registry image path (GitHub Packages)
        RAW_BASE="https://raw.githubusercontent.com/mfiers/pi-container/main"
        curl -fsSL "${RAW_BASE}/config.example.sh" -o "${CONFIG_FILE}" 2>/dev/null \
            || { echo "⚠  Could not fetch config template; creating a minimal one."; minimal_config; }
    else
        minimal_config() {
            cat > "${CONFIG_FILE}" << 'EOF'
# pi-container config — see config.example.sh for full docs
IMAGE_NAME="pi-devcontainer:latest"
CONTAINER_NAME="pi-dev"
ENABLE_TAILSCALE="true"
TAILSCALE_VOLUME="pi-tailscale-state"
EXTRA_MOUNTS=()
EXTRA_ENV=()
EXTRA_DOCKER_ARGS=()
EOF
        }
        minimal_config
    fi
    echo "✓ Config: ${CONFIG_FILE}"
    echo "  → Edit it to add extra mounts, GPU flags, etc."
else
    echo "  Config already exists — not overwriting: ${CONFIG_FILE}"
fi

# Load IMAGE_NAME from config so the launcher uses the right tag
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Override IMAGE_NAME if pulling from a specific registry
[[ -n "${REGISTRY}" ]] && IMAGE_NAME="${REGISTRY}"

# ── Install self-contained run.sh ─────────────────────────────────────────────
# We write a *copy* of run.sh into ~/.local/bin/pirun rather than a pointer
# to SCRIPT_DIR, so the launcher works even after the source repo is deleted.
mkdir -p "${BIN_DIR}"

if [[ -f "${SCRIPT_DIR}/run.sh" ]]; then
    # Embed the registry/image into the installed copy so it's self-contained
    sed "s|^IMAGE_NAME=.*|IMAGE_NAME=\"${IMAGE_NAME}\"|" \
        "${SCRIPT_DIR}/run.sh" > "${PIRUN}"
else
    # Fallback: fetch from GitHub
    curl -fsSL "https://raw.githubusercontent.com/yourname/pi-container/main/run.sh" \
        > "${PIRUN}"
fi
chmod +x "${PIRUN}"
echo "✓ Launcher: ${PIRUN}"

# ── PATH check ────────────────────────────────────────────────────────────────
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    echo ""
    echo "⚠  ${BIN_DIR} is not on your PATH."
    echo "   Add to ~/.bashrc or ~/.bash_profile:"
    echo '     export PATH="${HOME}/.local/bin:${PATH}"'
fi

# ── Get the Docker image ──────────────────────────────────────────────────────
echo ""
if [[ "${DO_BUILD}" == "false" && -n "${REGISTRY}" ]]; then
    # ── Pull from registry ────────────────────────────────────────────────────
    echo "Pulling ${REGISTRY} ..."
    docker pull "${REGISTRY}"
    # Tag as the local name so run.sh finds it
    [[ "${REGISTRY}" != "${IMAGE_NAME}" ]] \
        && docker tag "${REGISTRY}" "${IMAGE_NAME}"
    echo "✓ Image ready: ${IMAGE_NAME}"

elif [[ "${DO_BUILD}" == "true" && -f "${SCRIPT_DIR}/Dockerfile" ]]; then
    # ── Build locally ─────────────────────────────────────────────────────────
    echo "Building ${IMAGE_NAME} locally ..."
    "${SCRIPT_DIR}/build.sh" --tag "${IMAGE_NAME}"
    echo "✓ Image built: ${IMAGE_NAME}"

else
    # ── Defer: image will be auto-pulled by run.sh on first launch ────────────
    echo "⚠  No Dockerfile found and no registry specified."
    echo "   Set IMAGE_NAME in ${CONFIG_FILE} to an image that exists in a registry."
    echo "   pirun will attempt to pull it automatically on first launch."
fi

echo ""
echo "✓ Done.  Start a session with:"
echo "     pirun"
echo "  from any project directory."
