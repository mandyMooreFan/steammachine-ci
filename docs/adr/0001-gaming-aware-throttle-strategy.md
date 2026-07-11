# Gaming-aware throttle: pause by default, cap when a runner is enabled

When an **active game** is detected, the gaming watcher throttles the CI
container. We default to **hard pause** (`podman pause` → SIGSTOP the whole
container), and switch to **CPU cap** (`podman update --cpus=1`) only when the
opt-in self-hosted runner is enabled.

## Why not "pause and resume seamlessly"

The obvious appeal of pause is that it looks lossless. It isn't. SIGSTOP
freezes process *scheduling*, but `CLOCK_MONOTONIC` keeps advancing in real
time, and Playwright's test/action/`expect` timeouts are measured against it
(via Node/libuv timers). Pause a running test for a 90-minute gaming session
and, on unpause, every pending timeout fires at once and the test times out
immediately. The browser's live connections (CDP channel, dev server,
keep-alives) have also been dead for 90 minutes. So a run caught mid-flight is
**sacrificed** — you re-run it. Pause is a "yield the box to the game *now*"
mechanism, not a "continue exactly where it froze" one.

We accept that because, in the primary **manual/SSH** trigger model, the
overlap is rare: you kick off tests from your dev machine and are not usually
gaming on the box at the same moment. Paying for that rare case with a re-run
is cheap, and pause gives the cleanest possible framerate protection (CPU to
~0 instantly).

## Why cap instead of pause under the runner

The self-hosted GitHub Actions runner (opt-in, see the README) makes overlap
common — jobs fire on push regardless of what you're doing — and GitHub
enforces a *wall-clock* job timeout plus a runner heartbeat. A frozen runner
blows the timeout and looks offline. So under the runner, we cap to ~1 core:
the job keeps making real progress (timers advance in step with work) while
stealing little from the game.

## Considered options

- **CPU cap as the default** — keeps caught runs alive, but still contends
  with the game and a starved test can trip action timeouts. Rejected as the
  default because pause protects the game better and the manual model rarely
  overlaps.
- **Graceful cancel (SIGTERM the runner)** — honest, no zombie state, but
  throws away in-flight work unconditionally even for short freezes. Kept in
  reserve, not the default.
