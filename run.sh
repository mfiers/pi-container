#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# run.sh — Launch (or re-enter) the pi dev container
#
# Usage:
#   run.sh                    # interactive bash session
#   run.sh <command> [args]   # run a single command
#   run.sh --build            # (re)build the image first
#   run.sh --help
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults (overridable in config) ─────────────────────────────────────────
IMAGE_NAME="pi-devcontainer:latest"
CONTAINER_NAME="pi-dev"
TAILSCALE_VOLUME="pi-tailscale-state"
ENABLE_TAILSCALE="true"
CONTAINER_HOSTNAME="pi-dev"
REMOVE_ON_EXIT="true"     # --rm; set to "false" to keep for docker exec
EXTRA_MOUNTS=()
EXTRA_ENV=()
EXTRA_DOCKER_ARGS=()

# ── Global config ─────────────────────────────────────────────────────────────
CONFIG_FILE="${HOME}/.config/pi-container/config.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
elif [[ -f "${SCRIPT_DIR}/config.sh" ]]; then
    source "${SCRIPT_DIR}/config.sh"
fi

# ── Argument parsing ──────────────────────────────────────────────────────────
DO_BUILD=false
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build|-b)   DO_BUILD=true; shift ;;
        --help|-h)
            echo "Usage: run.sh [--build] [--help] [command [args...]]"
            echo ""
            echo "  --build, -b   Rebuild the Docker image before starting"
            echo "  --help,  -h   Show this help"
            echo ""
            echo "Config: ${CONFIG_FILE}"
            exit 0 ;;
        *)  PASSTHROUGH_ARGS+=("$1"); shift ;;
    esac
done

# ── Build if requested ────────────────────────────────────────────────────────
if [[ "${DO_BUILD}" == "true" ]]; then
    echo "🔨 Building ${IMAGE_NAME} ..."
    docker build \
        --platform "${DOCKER_PLATFORM:-linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}" \
        -t "${IMAGE_NAME}" \
        "${SCRIPT_DIR}"
fi

# ── Auto-pull if image is missing ────────────────────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    echo "Image '${IMAGE_NAME}' not found locally — pulling from registry ..."
    if ! docker pull "${IMAGE_NAME}"; then
        echo ""
        echo "✗ Could not pull '${IMAGE_NAME}'."
        echo "  Either build it:   ${SCRIPT_DIR}/build.sh"
        echo "  Or set IMAGE_NAME in ${CONFIG_FILE} to a pullable registry image."
        exit 1
    fi
fi

# ── Re-enter a running container ──────────────────────────────────────────────
# If a container with the canonical name is already running, exec into it.
if docker inspect "${CONTAINER_NAME}" --format '{{.State.Running}}' 2>/dev/null | grep -q "^true$"; then
    echo "↩ Container '${CONTAINER_NAME}' already running — exec-ing in"
    exec docker exec -it "${CONTAINER_NAME}" \
        gosu "${HOST_UID:-$(id -u)}" \
        "${PASSTHROUGH_ARGS[@]:-/bin/bash -l}"
fi

# ── Identity ──────────────────────────────────────────────────────────────────
HOST_UID=$(id -u)
HOST_GID=$(id -g)
HOST_USER=$(id -un)
CWD="$(pwd)"

# ── Tailscale state volume ────────────────────────────────────────────────────
if [[ "${ENABLE_TAILSCALE}" == "true" ]]; then
    docker volume create "${TAILSCALE_VOLUME}" >/dev/null 2>&1 || true
fi

# ── Build mount list ──────────────────────────────────────────────────────────
MOUNTS=()

# Helper: mount only if the source exists on the host
mount_ro() { [[ -e "$1" ]] && MOUNTS+=(-v "${1}:${1}:ro")  || true; }
mount_rw() { [[ -e "$1" ]] && MOUNTS+=(-v "${1}:${1}")     || true; }

# ── Current working directory (same path — scripts work unchanged) ────────────
MOUNTS+=(-v "${CWD}:${CWD}")

# ── Credentials / shell config (read-only) ────────────────────────────────────
mount_ro "${HOME}/.ssh"
mount_ro "${HOME}/.gitconfig"
mount_ro "${HOME}/.netrc"
mount_ro "${HOME}/.npmrc"
mount_ro "${HOME}/.yarnrc"
mount_ro "${HOME}/.gnupg"
mount_ro "${HOME}/.tmux.conf"
mount_ro "${HOME}/.bashrc"
mount_ro "${HOME}/.bash_profile"
mount_ro "${HOME}/.profile"
mount_ro "${HOME}/.bash_aliases"

# ── Tool state (read-write) ───────────────────────────────────────────────────
# pi agent
mount_rw "${HOME}/.pi"
mount_rw "${HOME}/.config/pi"
mount_rw "${HOME}/.local/share/pi"
# Claude
mount_rw "${HOME}/.claude"
mount_rw "${HOME}/.config/claude"
# Emacs
mount_rw "${HOME}/.emacs.d"
mount_rw "${HOME}/.config/emacs"
# uv / pip caches (speeds up repeated installs)
mount_rw "${HOME}/.cache/uv"
mount_rw "${HOME}/.cache/pip"
# Conda / micromamba envs (persist between sessions)
mount_rw "${HOME}/.mamba"
mount_rw "${HOME}/.conda"
# Generic config / local
mount_rw "${HOME}/.config/htop"
mount_rw "${HOME}/.local/share/fish"

# ── Tailscale persistent state ────────────────────────────────────────────────
if [[ "${ENABLE_TAILSCALE}" == "true" ]]; then
    MOUNTS+=(-v "${TAILSCALE_VOLUME}:/var/lib/tailscale")
fi

# ── Extra mounts from config ──────────────────────────────────────────────────
for extra in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do
    # Support bare paths (same-path mount) or full "src:dst[:opts]" specs
    if [[ "${extra}" != *:* ]]; then
        MOUNTS+=(-v "${extra}:${extra}")
    else
        MOUNTS+=(-v "${extra}")
    fi
done

# ── Environment ───────────────────────────────────────────────────────────────
ENV_ARGS=(
    -e "HOST_UID=${HOST_UID}"
    -e "HOST_GID=${HOST_GID}"
    -e "HOST_USER=${HOST_USER}"
    -e "HOST_HOME=${HOME}"
    -e "HOME=${HOME}"
    -e "USER=${HOST_USER}"
    -e "ENABLE_TAILSCALE=${ENABLE_TAILSCALE}"
    # Forward common API-key env vars if already set in the shell
    # (keys stay in shell environment, never baked into the image)
)

# Forward API keys that may already be in the environment
for key in \
    ANTHROPIC_API_KEY \
    OPENAI_API_KEY \
    GITHUB_TOKEN \
    HF_TOKEN \
    REPLICATE_API_TOKEN; do
    [[ -n "${!key:-}" ]] && ENV_ARGS+=(-e "${key}=${!key}")
done

for env_var in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do
    ENV_ARGS+=(-e "${env_var}")
done

# ── Security flags ────────────────────────────────────────────────────────────
#
#  --cap-drop ALL              start with zero capabilities
#  --cap-add ...               add back only what's needed:
#    CHOWN, SETUID, SETGID     → entrypoint creates user + gosu drops privs
#    DAC_OVERRIDE              → entrypoint writes skeleton dirs
#    NET_ADMIN, NET_RAW        → tailscale TUN interface management
#    SYS_PTRACE                → debugging (remove if not needed)
#  --security-opt no-new-privileges:true
#                              → once gosu drops, cannot re-escalate
#
SECURITY_FLAGS=(
    --cap-drop ALL
    --cap-add CHOWN
    --cap-add SETUID
    --cap-add SETGID
    --cap-add DAC_OVERRIDE
    --security-opt no-new-privileges:true
)

if [[ "${ENABLE_TAILSCALE}" == "true" ]]; then
    SECURITY_FLAGS+=(
        --cap-add NET_ADMIN
        --cap-add NET_RAW
    )
    # Add TUN device only if it exists on the host
    [[ -c /dev/net/tun ]] && SECURITY_FLAGS+=(--device /dev/net/tun)
fi

# ── Compose the final command ─────────────────────────────────────────────────
RM_FLAG=()
NAME_FLAG=(--name "${CONTAINER_NAME}")
if [[ "${REMOVE_ON_EXIT}" == "true" ]]; then
    RM_FLAG=(--rm)
    # Can't use a fixed name with --rm if we want re-attach logic;
    # use a session-unique name instead
    NAME_FLAG=(--name "${CONTAINER_NAME}-$$")
fi

echo "┌─────────────────────────────────────────────────────────┐"
echo "│  pi-devcontainer                                        │"
echo "├─────────────────────────────────────────────────────────┤"
printf "│  User   : %-45s │\n" "${HOST_USER} (${HOST_UID}:${HOST_GID})"
printf "│  CWD    : %-45s │\n" "${CWD}"
printf "│  Image  : %-45s │\n" "${IMAGE_NAME}"
printf "│  TS     : %-45s │\n" "${ENABLE_TAILSCALE}"
echo "└─────────────────────────────────────────────────────────┘"

exec docker run \
    --interactive \
    --tty \
    "${RM_FLAG[@]+"${RM_FLAG[@]}"}" \
    "${NAME_FLAG[@]}" \
    --hostname "${CONTAINER_HOSTNAME}" \
    --workdir  "${CWD}" \
    "${MOUNTS[@]}" \
    "${ENV_ARGS[@]}" \
    "${SECURITY_FLAGS[@]}" \
    "${EXTRA_DOCKER_ARGS[@]+"${EXTRA_DOCKER_ARGS[@]}"}" \
    "${IMAGE_NAME}" \
    "${PASSTHROUGH_ARGS[@]:-}"
