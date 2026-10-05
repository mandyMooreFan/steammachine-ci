# Steam Machine CI

Turns a Valve **Steam Machine** into a parallel Playwright build server that
yields the box to games while they run. This glossary pins the terms so the
scripts and docs don't drift into Steam Deck / handheld assumptions.

## Language

**Steam Machine**:
Valve's 2025 desktop cube (AMD Zen 4 6C/12T, RDNA3, 16GB RAM), always on AC
power and wired ethernet, running SteamOS 3. The build-server host.
_Avoid_: Steam Deck (a different, handheld device with a battery — its
constraints do not apply here), "the box".

**CI container**:
The single, long-lived Distrobox/Podman container (named `ci-runner`) holding
Node and Playwright; all projects are checkouts inside it. Lives under `$HOME`
so it survives SteamOS updates, which reset the read-only root filesystem
(see [[0002-container-under-home-not-native]]).
_Avoid_: VM, runner (the runner is an opt-in thing that runs *inside* it).

**Gaming watcher**:
The host-side daemon (a systemd *user* unit) that detects an active game and
throttles the CI container accordingly.
_Avoid_: monitor, poller.

**Active game**:
A Steam title that is actually running, detected via Steam's `reaper` launch
process (tagged `SteamLaunch AppId=<id>`). This is the trigger for throttling.
_Avoid_: "in Gaming Mode" and "gamescope running" — both are true the entire
time the box is in the game UI, even at the idle library, and do NOT mean a
game is running.

**Throttle**:
The act of yielding CPU to an active game. Two modes: **pause** (default) and
**cap** (see [[0001-gaming-aware-throttle-strategy]]).

**Sacrifice**:
The accepted outcome that a test run caught mid-flight by a *pause* will
likely fail on resume and must be re-run. Pause is a "yield now" mechanism,
not a "resume seamlessly" one.
