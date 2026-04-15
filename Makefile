# ────────────────────────────────────────────────────────────────────────────
# Makefile for pi-devcontainer
#
# Typical workflows
# ─────────────────
#  First machine (build + use locally):
#    make install
#
#  Push image to a registry so other machines can pull it:
#    make push REGISTRY=ghcr.io/yourname/pi-devcontainer:latest
#
#  Another machine (pull only — no Dockerfile needed):
#    make install-remote REGISTRY=ghcr.io/yourname/pi-devcontainer:latest
#
#  Or on the remote machine with just install.sh + run.sh copied over:
#    REGISTRY=ghcr.io/yourname/pi-devcontainer:latest ./install.sh
# ────────────────────────────────────────────────────────────────────────────

REGISTRY   ?=
IMAGE_NAME ?= pi-devcontainer:latest
PLATFORM   ?= linux/$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

.PHONY: help build push install install-remote run

help:          ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

# ── Local machine ─────────────────────────────────────────────────────────────
build:         ## Build image for local architecture
	./build.sh --tag $(IMAGE_NAME)

install:       ## Build image + install pirun locally
	./install.sh

run:           ## Launch a container session (auto-builds if needed)
	./run.sh

# ── Registry: push from this machine ─────────────────────────────────────────
push:          ## Build multi-arch image and push to REGISTRY
	@test -n "$(REGISTRY)" || (echo "Usage: make push REGISTRY=ghcr.io/you/pi-devcontainer:latest"; exit 1)
	./build.sh --multi --push --tag $(REGISTRY)
	@echo ""
	@echo "✓ Pushed.  To install on another machine:"
	@echo "   curl -fsSL https://raw.githubusercontent.com/yourname/pi-container/main/install.sh \\"
	@echo "     | REGISTRY=$(REGISTRY) bash"
	@echo ""
	@echo "   OR copy install.sh + run.sh and run:"
	@echo "   ./install.sh --from-registry $(REGISTRY)"

# ── Remote machine (no source repo needed) ───────────────────────────────────
install-remote:  ## Pull pre-built image and install pirun (no Dockerfile needed)
	@test -n "$(REGISTRY)" || (echo "Usage: make install-remote REGISTRY=ghcr.io/you/pi-devcontainer:latest"; exit 1)
	./install.sh --from-registry $(REGISTRY)
