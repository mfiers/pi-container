# ────────────────────────────────────────────────────────────────────────────
# pi-container global configuration
# Copy to: ~/.config/pi-container/config.sh
#
# This file is sourced as bash, so you can use variables, conditionals, etc.
# ────────────────────────────────────────────────────────────────────────────

# ── Image / container identity ────────────────────────────────────────────────
IMAGE_NAME="mfiers/pi-devcontainer:latest"
CONTAINER_NAME="pi-dev"          # used for re-attach detection
CONTAINER_HOSTNAME="pi-dev"

# ── Behaviour ─────────────────────────────────────────────────────────────────
REMOVE_ON_EXIT="true"            # "false" → keep container for docker exec

# ── Tailscale ─────────────────────────────────────────────────────────────────
ENABLE_TAILSCALE="true"
TAILSCALE_VOLUME="pi-tailscale-state"   # named Docker volume for TS state

# ── Extra bind mounts ─────────────────────────────────────────────────────────
# Formats:
#   "/absolute/path"                 → mounted at same path (rw)
#   "/host/path:/container/path"     → explicit mapping (rw)
#   "/host/path:/container/path:ro"  → read-only
#
EXTRA_MOUNTS=(
    # Large datasets / model weights
    # "/data/datasets:/data/datasets:ro"
    # "/data/models"

    # Shared scratch space across containers
    # "/tmp/shared-scratch"

    # Project roots outside CWD
    # "$HOME/projects"
)

# ── Extra environment variables ───────────────────────────────────────────────
# Prefer putting secrets in ~/.bashrc / ~/.profile on the host so they're
# forwarded automatically (run.sh already does this for common API keys).
# Use EXTRA_ENV only for container-specific overrides.
#
EXTRA_ENV=(
    # "HF_HOME=/data/huggingface"
    # "TRANSFORMERS_CACHE=/data/huggingface/hub"
    # "WANDB_DIR=/tmp"
)

# ── Extra docker run arguments ────────────────────────────────────────────────
EXTRA_DOCKER_ARGS=(
    # Resource limits
    # "--memory=32g"
    # "--cpus=16"
    # "--shm-size=8g"          # needed for PyTorch DataLoader workers

    # GPU passthrough (NVIDIA)
    # "--gpus=all"
    # "--runtime=nvidia"

    # Stronger isolation with gVisor (install runsc on host first)
    # "--runtime=runsc"

    # Expose a port (e.g. Jupyter, gradio)
    # "-p 8888:8888"
    # "-p 7860:7860"

    # Network: "host" gives full host networking (simplest, least isolated)
    # "--network=host"
)

# ── Platform override (for cross-arch on Mac) ─────────────────────────────────
# Uncomment on Apple Silicon if you pull a pre-built amd64 image:
# DOCKER_PLATFORM="linux/amd64"
# Uncomment to force native arm64:
# DOCKER_PLATFORM="linux/arm64"
