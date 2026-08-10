# Steam Machine CI

Use your steammachine to run CI/CD

the 2025 desktop cube — AMD Zen 4 6C/12T, RDNA3, 16GB RAM

turns off when you open a game. starts up when you close a game.

## What you get

- One idempotent `install.sh` that sets the whole thing up and is safe to
  re-run after any SteamOS update.

## Quick start

On the Steam Machine — switch to **Desktop Mode** (Steam → Power → Switch to
Desktop), open **Konsole**, and (recommended) enable SSH so you can drive it
from your dev machine:

```bash
passwd                              # set a password for the 'deck' user
sudo systemctl enable --now sshd
ip addr                             # note the LAN IP, or use <hostname>.local
```

Then:

```bash
git clone <this-repo> ~/steam-machine-ci
cd ~/steam-machine-ci
./install.sh
```

That installs Distrobox/Podman (if needed), creates and provisions the
`ci-runner` container, installs the watcher as a systemd **user** unit, enables
it, and turns on `linger` so it runs at boot without a graphical login.

## Running tests

From your dev machine: `ssh deck@<host>.local`, then work inside the container:

```bash
distrobox enter ci-runner
git clone <your-project> && cd <your-project>
npm ci
npx playwright install                # browser binaries for THIS project
npx playwright test --workers=8
```

### Parallelism and the `--workers` number

The default suggestion is **`--workers=8`**, but the real ceiling is **RAM,
not cores**. You have 16GB of system memory (the 8GB GDDR6 is VRAM, separate);
SteamOS eats ~1.5–2GB, and each browser worker is ~0.3–0.7GB+ under load — more
on heavy pages, and more again if the app-under-test's dev server also runs on
the box. Push toward 10–12 workers only if `free -m` shows headroom; back off
if you see swapping or the OOM killer. More workers than RAM allows is *slower*,
not faster. Playwright prints the actual wall-clock speedup in its summary.

For sharding across CI invocations:
`npx playwright test --shard=1/3 --workers=8`.

## How the gaming-aware throttle works

The watcher (`~/.local/bin/gaming-watcher.sh`) polls every 5s for Steam's
launch process — `reaper … SteamLaunch AppId=<id>` — which exists **only while
a real game is running**.

> It does **not** watch for `gamescope`. On SteamOS `gamescope` is the
> session compositor and runs the *entire* time the box is in Gaming Mode, even
> at the idle library — watching it would strangle CI whenever you're anywhere
> near the game UI.

- **Game launched → `podman pause ci-runner`.** SIGSTOP to every process in the
  container; CPU draw drops to ~0 instantly, protecting the game's framerate.
- **Game closed → `podman unpause ci-runner`.**

### Important: a run caught mid-game is sacrificed

Pause is a "yield the box **now**" mechanism, not a "resume exactly where it
froze" one. `CLOCK_MONOTONIC` keeps advancing under SIGSTOP, so a Playwright
run frozen for a real gaming session will hit all its timeouts the moment it
resumes (and its browser's network connections will have died meanwhile). So:
**if you start a game while tests are running, expect to re-run that batch.**
In the manual/SSH workflow this overlap is rare, so it's a cheap price for the
cleanest possible framerate protection. Full rationale:
[ADR-0001](docs/adr/0001-gaming-aware-throttle-strategy.md).

### Watching the watcher

```bash
systemctl --user status ci-watcher.service
journalctl --user -u ci-watcher.service -f
```

### Optional: cpu-cap instead of full pause

If you'd rather keep runs limping along on one core while gaming (instead of
pausing), edit `~/.config/systemd/user/ci-watcher.service`, uncomment:

```ini
Environment=THROTTLE_MODE=cap
Environment=CAP_CPUS=1
```

then `systemctl --user daemon-reload && systemctl --user restart ci-watcher.service`.
This is the recommended mode if you enable the self-hosted runner (below).

## Why manual/SSH, not a "real" CI runner (by default)

The default trigger model is **you SSH in and run `npx playwright test`**.
That keeps the pause/resume story clean and needs no inbound auth or external
service. It's the right shape for a home box you also game on.

### Opt-in: self-hosted GitHub Actions runner

If you want pushes/PRs to trigger runs automatically, register the container as
a self-hosted runner:

```bash
distrobox enter ci-runner
mkdir actions-runner && cd actions-runner
# follow GitHub → repo/org → Settings → Actions → Runners → New self-hosted runner
./config.sh --url https://github.com/<you>/<repo> --token <TOKEN>
./run.sh      # or install it as its own service inside the container
```

**If you do this, switch the watcher to `THROTTLE_MODE=cap`** (see above).
GitHub enforces a *wall-clock* job timeout and expects runner heartbeats — a
fully paused runner blows the timeout and looks offline, whereas a capped
runner keeps making real progress on one core while you game.

## Files

| File | Role |
|------|------|
| `install.sh` | Idempotent full bootstrap (host + container). Safe to re-run. |
| `gaming-watcher.sh` | The throttle daemon (runs on the SteamOS host). |
| `ci-watcher.service` | systemd **user** unit that keeps the watcher running. |
| `CONTEXT.md` | Glossary — the canonical terms for this project. |
| `docs/adr/` | Architecture decision records. |
