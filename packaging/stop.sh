#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
for arg in "$@"; do
    case "$arg" in
        --plain) ;;
        --help|-h)
            printf 'Usage: stop.sh [--plain]\nSend SIGTERM only to this project\047s exported Linux executable.\nSave in the game before stopping it. No broad process matching or forced kill.\n'
            exit 0 ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
project_environment
command -v flock >/dev/null || fail 'flock is required to serialize launcher operations.'
exec 9>"$TD_ROOT/tmp/lifecycle.lock"
flock -n 9 || fail 'Another launch, stop, or build is in progress.'
mapfile -t td_pids < <(game_pids)
if (( ${#td_pids[@]} == 0 )); then info State 'Already stopped'; exit 0; fi
for td_pid in "${td_pids[@]}"; do
    if is_game_pid "$td_pid"; then
        if ! kill -TERM -- "$td_pid"; then
            is_game_pid "$td_pid" && fail "Unable to stop PID $td_pid."
            continue
        fi
        info Stopping "PID $td_pid"
    fi
done
for ((attempt=0; attempt<50; attempt++)); do
    if [[ -z "$(game_pids)" ]]; then info State 'Stopped'; exit 0; fi
    sleep 0.1
done
fail 'The game is still running after SIGTERM; inspect it manually. No forced kill was sent.'
