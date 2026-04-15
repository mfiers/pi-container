#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────────────────
# build.sh — Build (or multi-arch push) the pi-devcontainer image
#
# Usage:
#   ./build.sh                         # build for local arch
#   ./build.sh --push --tag myrepo/pi  # build multi-arch + push to registry
#   ./build.sh --arm                   # cross-build arm64 locally (needs buildx)
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
IMAGE_TAG="pi-devcontainer:latest"
PLATFORMS="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
PUSH=false
BUILDER_NAME="pi-devcontainer-builder"
CACHE_FROM=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag|-t)       IMAGE_TAG="$2";    shift 2 ;;
        --push|-p)      PUSH=true;         shift   ;;
        --arm)          PLATFORMS="linux/arm64";   shift ;;
        --multi)        PLATFORMS="linux/amd64,linux/arm64"; shift ;;
        --cache-from)   CACHE_FROM="$2";   shift 2 ;;
        --help|-h)
            echo "Usage: build.sh [--tag IMAGE] [--push] [--arm] [--multi] [--cache-from IMAGE]"
            exit 0 ;;
        *)  echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "Building: ${IMAGE_TAG}"
echo "Platform: ${PLATFORMS}"

# ── Single-arch local build (docker build, no buildx needed) ─────────────────
if [[ "${PUSH}" == "false" && "${PLATFORMS}" != *","* ]]; then
    docker build \
        --platform "${PLATFORMS}" \
        ${CACHE_FROM:+--cache-from "${CACHE_FROM}"} \
        -t "${IMAGE_TAG}" \
        "${SCRIPT_DIR}"
    echo "✓ Image built: ${IMAGE_TAG}"
    exit 0
fi

# ── Multi-arch or push build (requires docker buildx) ─────────────────────────
# Ensure our custom builder exists
if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
    echo "Creating buildx builder '${BUILDER_NAME}' ..."
    docker buildx create \
        --name  "${BUILDER_NAME}" \
        --driver docker-container \
        --use
else
    docker buildx use "${BUILDER_NAME}"
fi

PUSH_FLAG="--load"
[[ "${PUSH}" == "true" ]] && PUSH_FLAG="--push"

docker buildx build \
    --platform "${PLATFORMS}" \
    ${CACHE_FROM:+--cache-from "type=registry,ref=${CACHE_FROM}"} \
    ${PUSH:+--cache-to  "type=registry,ref=${IMAGE_TAG}-cache,mode=max"} \
    "${PUSH_FLAG}" \
    -t "${IMAGE_TAG}" \
    "${SCRIPT_DIR}"

echo "✓ Done: ${IMAGE_TAG} (${PLATFORMS})"
