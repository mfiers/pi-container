# pi-devcontainer

A secure, reproducible AI development environment in Docker.

**Inside the container:**
- 🐍 **uv** — ultra-fast Python package/project manager (Astral)
- 🐍 **micromamba** — standalone conda-compatible environment manager
- 🔒 **Tailscale** — VPN with persistent login (one-time auth)
- Debian Bookworm slim base
- Runs as **your exact UID/GID** → file ownership is always correct
- CWD and selected `$HOME` config dirs bind-mounted at **identical paths** → scripts work identically inside and outside

---

## Quick start

```bash
# 1. Install (creates config, builds image, adds `pirun` to PATH)
./install.sh

# 2. Launch a session from any project directory
cd ~/projects/my-project
pirun

# 3. Or rebuild + launch in one step
pirun --build
```

---

## Installing on another machine

Two paths depending on whether you want to build or pull a pre-built image.

### Path A — pull from a registry (recommended, no Dockerfile needed)

**On the first machine:** push the image once:
```bash
make push REGISTRY=ghcr.io/yourname/pi-devcontainer:latest
# builds multi-arch (amd64 + arm64) and pushes
```

**On every other machine:** only `install.sh` and `run.sh` are needed:
```bash
# Option 1 — copy two files manually or via scp:
scp install.sh run.sh other-host:~/pi-container/
ssh other-host 'cd ~/pi-container && ./install.sh --from-registry ghcr.io/yourname/pi-devcontainer:latest'

# Option 2 — curl directly from GitHub (if repo is public):
bash <(curl -fsSL https://raw.githubusercontent.com/yourname/pi-container/main/install.sh) \
  --from-registry ghcr.io/yourname/pi-devcontainer:latest

# Option 3 — env var (for scripting / dotfiles bootstrap):
REGISTRY=ghcr.io/yourname/pi-devcontainer:latest \
  bash <(curl -fsSL https://raw.githubusercontent.com/yourname/pi-container/main/install.sh)
```

After that, `pirun` on the remote machine auto-pulls the image on first launch
if it's not cached locally yet — no build step, no Dockerfile.

### Path B — clone and build everywhere

Needs Docker only (and `git`):
```bash
git clone https://github.com/yourname/pi-container.git
cd pi-container
./install.sh          # builds image locally, installs pirun
```

### What each machine actually needs

| Scenario | Files needed on target |
|----------|------------------------|
| Pull from registry | `install.sh` + `run.sh` (and Docker) |
| Build locally | Full repo (and Docker + internet) |
| After `install.sh` runs | Nothing — `pirun` is self-contained in `~/.local/bin` |

---

## How it works

### Same-path CWD mount
```
Host:       /home/you/projects/my-project
Container:  /home/you/projects/my-project   ← identical
```
Any script that hardcodes or resolves paths works unchanged.

### User identity
The container starts as `root`, creates a matching user entry for your
`UID:GID`, then `gosu` drops to that user before the shell opens.
You own every file you create.

### Config mounts
| Host path            | Container  | Mode |
|----------------------|------------|------|
| `~/.ssh`             | same       | ro   |
| `~/.gitconfig`       | same       | ro   |
| `~/.bashrc`          | same       | ro   |
| `~/.tmux.conf`       | same       | ro   |
| `~/.gnupg`           | same       | ro   |
| `~/.pi` / `~/.config/pi` | same   | rw   |
| `~/.claude`          | same       | rw   |
| `~/.emacs.d`         | same       | rw   |
| `~/.mamba`           | same       | rw   |
| `~/.cache/uv`        | same       | rw   |

Add more in `~/.config/pi-container/config.sh`.

---

## Configuration

Copy the example and customise:
```bash
cp config.example.sh ~/.config/pi-container/config.sh
$EDITOR ~/.config/pi-container/config.sh
```

Key options:
```bash
# Extra bind mounts
EXTRA_MOUNTS=(
    "/data/models:/data/models:ro"
    "$HOME/shared-projects"
)

# Resource limits
EXTRA_DOCKER_ARGS=(
    "--memory=32g"
    "--cpus=16"
    "--gpus=all"          # NVIDIA GPU passthrough
)

# Disable tailscale if not needed
ENABLE_TAILSCALE="false"
```

---

## Tailscale (one-time login)

Tailscale state is stored in a Docker named volume (`pi-tailscale-state`),
so you authenticate **once** and it persists forever.

```bash
# First time only — inside the container:
tailscale up

# Follow the printed URL in your browser to authenticate.
# Every subsequent container start will reconnect automatically.

# Check status any time:
tailscale status
```

The volume survives `docker rm`.  To reset:
```bash
docker volume rm pi-tailscale-state
```

---

## Build

```bash
# Local architecture (amd64 or arm64 auto-detected)
./build.sh

# Force arm64 (Apple Silicon)
./build.sh --arm

# Multi-arch + push to registry
./build.sh --multi --push --tag yourname/pi-devcontainer:latest
```

---

## Security model

### What's enabled
| Feature | Why |
|---------|-----|
| `--cap-drop ALL` | Start with zero Linux capabilities |
| `--cap-add CHOWN,SETUID,SETGID,DAC_OVERRIDE` | Entrypoint user setup + gosu |
| `--cap-add NET_ADMIN,NET_RAW` | Tailscale TUN interface (omitted when Tailscale disabled) |
| `--security-opt no-new-privileges` | Blocks privilege re-escalation after `gosu` drops to user |
| Read-only mounts for credentials | `.ssh`, `.gitconfig`, `.gnupg`, `.bashrc` etc. can't be modified by container code |
| Named volume for TS state | Tailscale state isolated from host filesystem |

### What's NOT in scope (threat model)
This container protects your **host system** from bugs or malicious behaviour
in AI-generated code that runs inside the container.  It does **not**:
- Prevent the container from making outbound network requests (use `--network=none` or a firewall rule if needed)
- Prevent exfiltration of files under the mounted CWD

### Stronger isolation options

**gVisor** (recommended for running untrusted AI-generated code):
```bash
# Install runsc on the host: https://gvisor.dev/docs/user_guide/install/
# Then in config.sh:
EXTRA_DOCKER_ARGS=("--runtime=runsc")
```
gVisor intercepts all syscalls in a user-space kernel — even a container
escape attempt hits another sandbox layer.

**Kata Containers** — full micro-VM isolation, higher overhead:
```bash
EXTRA_DOCKER_ARGS=("--runtime=kata-runtime")
```

**Rootless Docker** — run the Docker daemon itself as a non-root user:
```bash
# https://docs.docker.com/engine/security/rootless/
dockerd-rootless-setuptool.sh install
```

**Read-only root filesystem** (advanced):
```bash
EXTRA_DOCKER_ARGS=(
    "--read-only"
    "--tmpfs /tmp:rw,noexec,nosuid,size=512m"
    "--tmpfs /run:rw,noexec,nosuid,size=64m"
)
```

---

## Third-party alternatives worth knowing

| Tool | Best for |
|------|----------|
| [**Distrobox**](https://distrobox.it/) | Seamless home-dir integration, no Dockerfile needed |
| [**DevPod**](https://devpod.sh/) | devcontainer spec + cloud/local/k8s backends |
| [**devcontainer CLI**](https://containers.dev/) | VS Code / JetBrains standard format |
| [**gVisor**](https://gvisor.dev/) | Strongest isolation for untrusted code |
| [**Toolbox**](https://containertoolbx.org/) | RHEL/Fedora-oriented, similar to Distrobox |

For pure network-level AI sandboxing (restrict what the AI can reach):
- [**Dangerzone**](https://dangerzone.rocks/) — document sandboxing via containers
- Custom `iptables` / `nftables` rules on the Docker bridge network

---

## Apple Silicon / Mac M-series

```bash
# Build native arm64 image (faster, no emulation)
./build.sh --arm

# Or pull and run with Rosetta emulation (amd64 image):
EXTRA_DOCKER_ARGS=("--platform=linux/amd64") pirun
```

On macOS, `/dev/net/tun` is not available via Docker Desktop.
Tailscale automatically falls back to **userspace networking** in that case
(slightly lower performance, fully transparent to applications).

---

## File layout

```
picontainer/
├── Dockerfile          # Image definition
├── entrypoint.sh       # Root setup → gosu drop → tailscaled
├── run.sh              # Launch / re-attach script
├── build.sh            # Build helper (single + multi-arch)
├── install.sh          # One-time local install
├── config.example.sh   # → copy to ~/.config/pi-container/config.sh
├── .dockerignore
└── README.md
```
