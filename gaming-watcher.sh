#!/usr/bin/env bash
#
# gaming-watcher.sh
#
# Host-side daemon (installed as a systemd *user* unit) that yields the Steam
# Machine to games. It detects an ACTIVE GAME via Steam's reaper launch
# process ("SteamLaunch AppId=<id>") -- deliberately NOT via `gamescope`,
# which runs the entire time the box is in Gaming Mode, even at the idle
# library, and therefore does not mean a game is running.
#
# While a game runs it throttles the ci-runner container:
#   THROTTLE_MODE=pause  (default)  -> podman pause / unpause
#   THROTTLE_MODE=cap               -> podman update --cpus=<CAP|IDLE>
#
# Pause is a "yield the box NOW" mechanism, not a "resume exactly where it
# froze" one: CLOCK_MONOTONIC keeps advancing under SIGSTOP, so a Playwright
# run caught mid-flight by a long pause will hit its timeouts on resume and
# must be re-run. See docs/adr/0001-gaming-aware-throttle-strategy.md.

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-ci-runner}"
POLL_SECONDS="${POLL_SECONDS:-5}"
THROTTLE_MODE="${THROTTLE_MODE:-pause}"      # pause | cap
CAP_CPUS="${CAP_CPUS:-1}"                     # cores while gaming (cap mode)
IDLE_CPUS="${IDLE_CPUS:-$(nproc)}"            # cores while idle  (cap mode)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') gaming-watcher: $*"; }

container_status() {
    # running | paused | exited | missing
    podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing
}

is_gaming() {
    # Steam launches every title through: .../reaper SteamLaunch AppId=<id> -- ...
    # (native games and non-Steam shortcuts alike). That process is present
    # only while a real game is running.
    pgrep -f 'SteamLaunch AppId=' >/dev/null 2>&1
}

current_nanocpus() {
    podman inspect -f '{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null || echo 0
}

set_cpus() {
    local cpus="$1" want_nano
    want_nano=$(awk "BEGIN{printf \"%.0f\", $cpus*1000000000}")
    if [ "$(current_nanocpus)" != "$want_nano" ]; then
        log "cap -> cpus=$cpus on $CONTAINER_NAME"
        podman update --cpus="$cpus" "$CONTAINER_NAME" >/dev/null || log "cpu update failed"
    fi
}

throttle_pause() {
    local status="$1" gaming="$2"
    if [ "$gaming" = yes ] && [ "$status" = running ]; then
        log "game detected -> pausing $CONTAINER_NAME (any in-flight run is sacrificed)"
        podman pause "$CONTAINER_NAME" >/dev/null || log "pause failed (already paused?)"
    elif [ "$gaming" = no ] && [ "$status" = paused ]; then
        log "no game -> unpausing $CONTAINER_NAME"
        podman unpause "$CONTAINER_NAME" >/dev/null || log "unpause failed"
    fi
}

throttle_cap() {
    local status="$1" gaming="$2"
    # cap mode never pauses; if something else left it paused, resume it first.
    [ "$status" = paused ] && podman unpause "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [ "$gaming" = yes ]; then
        set_cpus "$CAP_CPUS"
    else
        set_cpus "$IDLE_CPUS"
    fi
}

log "starting: container=$CONTAINER_NAME mode=$THROTTLE_MODE poll=${POLL_SECONDS}s"
[ "$THROTTLE_MODE" = cap ] && log "cap mode: gaming=${CAP_CPUS} idle=${IDLE_CPUS} cpus"

while true; do
    status="$(container_status)"

    if [ "$status" = missing ]; then
        log "container '$CONTAINER_NAME' not found; waiting"
        sleep "$POLL_SECONDS"; continue
    fi

    if is_gaming; then gaming=yes; else gaming=no; fi

    case "$THROTTLE_MODE" in
        pause) throttle_pause "$status" "$gaming" ;;
        cap)   throttle_cap   "$status" "$gaming" ;;
        *)     log "unknown THROTTLE_MODE '$THROTTLE_MODE'; falling back to pause"
               throttle_pause "$status" "$gaming" ;;
    esac

    sleep "$POLL_SECONDS"
done
