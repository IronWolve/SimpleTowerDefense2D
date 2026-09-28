#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
td_status=false
for arg in "$@"; do
    case "$arg" in
        --plain) ;;
        --status) td_status=true ;;
        --help|-h)
            printf 'Usage: start.sh [--plain] [--status]\nLaunch the exported Linux game with a project-local profile and logs.\nRebuild after changing game source. --status never launches the game.\n'
            exit 0 ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
if "$td_status"; then game_status; exit 0; fi
validate_project_paths
require_local_path "$TD_GAME"
require_local_path "$TD_ROOT/logs/game.log"
require_local_path "$TD_ROOT/logs/console.log"
[[ -x "$TD_GAME" ]] || fail 'No Linux export. Run ./build.sh linux first.'
[[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || fail 'No graphical display is available. Launch from a desktop session.'
command -v flock >/dev/null || fail 'flock is required to serialize launcher operations.'
project_environment
exec 9>"$TD_ROOT/tmp/lifecycle.lock"
flock -n 9 || fail 'Another launch, stop, or build is in progress.'
if [[ -n "$(game_pids)" ]]; then game_status; exit 0; fi
info Renderer 'GL Compatibility; display and GPU selected by Godot'
(
    cd -- "$(dirname -- "$TD_GAME")"
    exec nohup ./SimpleTowerDefense2D.x86_64 --log-file ../../logs/game.log
) \
    </dev/null >>"$TD_ROOT/logs/console.log" 2>&1 9>&- &
td_pid=$!
sleep 0.3
is_game_pid "$td_pid" || fail "Game exited during startup; inspect $TD_ROOT/logs/console.log"
game_status
info Stop "$TD_ROOT/stop.sh (save in the game first)"
