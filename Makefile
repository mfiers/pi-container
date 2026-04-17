IMAGE_NAME ?= mfiers/pi-devcontainer:latest
REGISTRY   ?= $(IMAGE_NAME)
PLATFORM   ?= linux/$(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

.PHONY: help build push install install-remote run

help:  ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

# -- Local machine ------------------------------------------------------------

build:  ## Build image for local architecture
	./build.sh --tag $(IMAGE_NAME)

install:  ## Build image + install pirun locally
	./install.sh

run:  ## Launch a container session via Docker (auto-pulls image if not present)
	./run.sh

run-apptainer:  ## Launch a container session via Apptainer (pulls SIF if missing)
	./apptainer-run.sh

install-apptainer:  ## Install pirun using Apptainer (no Docker needed)
	./install.sh

pull-apptainer:  ## Update the Apptainer SIF to the latest image from the registry
	./apptainer-run.sh --pull

# -- Registry: push from this machine -----------------------------------------

push:  ## Build multi-arch image and push to Docker Hub (defaults to mfiers/pi-devcontainer:latest)
	@test -n "$(REGISTRY)" || { echo "Usage: make push [REGISTRY=image:tag]"; exit 1; }
	./build.sh --multi --push --tag $(REGISTRY)
	@echo ""
	@echo "Pushed: $(REGISTRY)"
	@echo ""
	@echo "To install on another machine (only install.sh + run.sh needed):"
	@echo "  ./install.sh --from-registry $(REGISTRY)"

# -- Remote machine (no source repo needed) -----------------------------------

install-remote:  ## Pull pre-built image and install pirun (no Dockerfile needed)
	@test -n "$(REGISTRY)" || { echo "Usage: make install-remote REGISTRY=mfiers/pi-devcontainer:latest"; exit 1; }
	./install.sh --from-registry $(REGISTRY)
