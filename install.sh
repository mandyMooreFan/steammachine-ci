#!/usr/bin/env bash
#
# install.sh -- full, idempotent bootstrap of the Steam Machine as a Playwright
# build server. Run it ON the Steam Machine (Desktop Mode terminal or over SSH):
#
#   git clone <this-repo> ~/steam-machine-ci
#   cd ~/steam-machine-ci && ./install.sh
#
# It only ever writes under $HOME, so it is safe to re-run after a SteamOS
# update (which resets the read-only root). See
# docs/adr/0002-container-under-home-not-native.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-ci-runner}"
IMAGE="${IMAGE:-ubuntu:24.04}"
NODE_MAJOR="${NODE_MAJOR:-22}"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"

log()  { echo -e "\n== $* =="; }
have() { command -v "$1" >/dev/null 2>&1; }

# distrobox/podman may live in ~/.local/bin; make sure it's reachable.
export PATH="$BIN_DIR:$PATH"

log "1/6  host-side directories"
mkdir -p "$BIN_DIR" "$UNIT_DIR"

log "2/6  gaming watcher + systemd user unit"
install -m 0755 "$REPO_DIR/gaming-watcher.sh" "$BIN_DIR/gaming-watcher.sh"
install -m 0644 "$REPO_DIR/ci-watcher.service" "$UNIT_DIR/ci-watcher.service"

log "3/6  podman + distrobox"
if ! have podman; then
    echo "podman not found. Current SteamOS images ship it built-in."
    echo "If it is genuinely missing, install podman, then re-run this script."
    exit 1
fi
if ! have distrobox; then
    echo "installing distrobox into ~/.local (survives SteamOS updates)"
    curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install \
        | sh -s -- --prefix "$HOME/.local"
fi

log "4/6  ci-runner container ($IMAGE)"
if podman container exists "$CONTAINER_NAME"; then
    echo "container '$CONTAINER_NAME' already exists; leaving it untouched."
    echo "To rebuild it from scratch: podman rm -f $CONTAINER_NAME && ./install.sh"
else
    distrobox create --yes --name "$CONTAINER_NAME" --image "$IMAGE"
    echo "provisioning Node ${NODE_MAJOR} + Playwright system deps (one-time)..."
    distrobox enter "$CONTAINER_NAME" -- bash -euc "
        sudo apt-get update
        sudo apt-get install -y curl ca-certificates git
        curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
        sudo apt-get install -y nodejs
        # Browser SYSTEM libraries only -- browser binaries are per project.
        sudo npx --yes playwright@latest install-deps
    "
fi

log "5/6  enable the watcher (systemd user unit)"
systemctl --user daemon-reload
systemctl --user enable --now ci-watcher.service

log "6/6  keep the watcher running without a login (linger)"
loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"

cat <<EOF

Done. The gaming watcher is running and will start on boot.

  Status:  systemctl --user status ci-watcher.service
  Logs:    journalctl --user -u ci-watcher.service -f

Per project (inside the container):
  distrobox enter $CONTAINER_NAME
  git clone <your-project> && cd <your-project>
  npm ci
  npx playwright install                 # browser binaries (per project)
  npx playwright test --workers=8        # tune to taste; RAM is the ceiling

Throttle mode is 'pause' by default. To switch to cpu-cap (recommended if you
enable the self-hosted runner), edit:
  $UNIT_DIR/ci-watcher.service
uncomment the Environment lines, then:
  systemctl --user daemon-reload && systemctl --user restart ci-watcher.service
EOF
