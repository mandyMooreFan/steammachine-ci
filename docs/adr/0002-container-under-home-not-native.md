# The CI toolchain lives in a Distrobox/Podman container under $HOME, not natively

Node, Playwright, and the browsers run inside a single long-lived Distrobox
(Podman) container named `ci-runner`, created under `$HOME`. We deliberately
do **not** install any of it natively with `pacman`.

## Why

SteamOS's root filesystem is **read-only and gets reset on every OS update**.
Anything installed natively with `pacman` (and any system-level `systemd`
unit under `/etc`) vanishes after the next SteamOS patch. Distrobox + Podman
put the entire toolchain in a container image stored under `$HOME`, on the
writable user partition, so it survives updates indefinitely. For the same
reason the gaming watcher is installed as a **user** systemd unit under
`~/.config/systemd/user` (never `/etc`), with `loginctl enable-linger` so it
starts at boot without a graphical login.

## Consequences

- The only recurring maintenance is per-project setup inside the container;
  the container itself is created once and persists across SteamOS updates.
- `install.sh` must be idempotent and touch only `$HOME` — re-running it after
  an update must be safe and must never assume anything was written to the
  read-only root.
