#!/usr/bin/env bash
# Shared by source build scripts and the deployed launchers.
TD_SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
TD_PROJECT_DIR="$(cd -- "$TD_SCRIPT_DIR/../.." && pwd -P)"
# Resolve the location once, then keep project file operations relative to it.
cd -- "$TD_PROJECT_DIR"
TD_ROOT=.
TD_GAME="$TD_ROOT/run/linux/SimpleTowerDefense2D.x86_64"
TD_PROFILE="$TD_ROOT/.config/data/godot/app_userdata/Simple Tower Defense 2D"
TD_COLOR='' TD_RESET=''
if [[ -t 1 && -z "${NO_COLOR:-}" && " ${*} " != *' --plain '* ]]; then
    TD_COLOR=$'\033[1;36m' TD_RESET=$'\033[0m'
fi
info() { printf '%s%-12s%s %s\n' "$TD_COLOR" "$1" "$TD_RESET" "$2"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_local_path() {
    local path="${1#./}"
    case "$path" in ''|.|..|/*|../*|*/../*|*/..) fail "Expected a project-relative path: $1" ;; esac
    [[ "$(readlink -m -- "$path")" == "$TD_PROJECT_DIR/$path" && ! -L "$path" ]] \
        || fail "Project path must not contain symlinks: $1"
}
validate_project_paths() {
    local path
    for path in run run/linux run/launchers .config .config/data logs .cache .cache/build-backups tmp tmp/lifecycle.lock; do
        require_local_path "$TD_ROOT/$path"
    done
}
project_environment() {
    validate_project_paths
    umask 077
    # XDG and temporary-directory APIs require absolute values. These are
    # calculated for this invocation and never saved in configuration or builds.
    export XDG_CONFIG_HOME="$TD_PROJECT_DIR/.config"
    export XDG_DATA_HOME="$TD_PROJECT_DIR/.config/data"
    export XDG_CACHE_HOME="$TD_PROJECT_DIR/.cache"
    export TMPDIR="$TD_PROJECT_DIR/tmp" TMP="$TD_PROJECT_DIR/tmp" TEMP="$TD_PROJECT_DIR/tmp"
    mkdir -p -- run logs .config .config/data .cache tmp
}
is_game_pid() {
    local actual
    actual="$(readlink -- "/proc/$1/exe" 2>/dev/null)" || return 1
    [[ "$actual" == "$TD_PROJECT_DIR/${TD_GAME#./}" || "$actual" == "$TD_PROJECT_DIR/${TD_GAME#./} (deleted)" ]]
}
game_pids() {
    local proc pid
    for proc in /proc/[0-9]*/exe; do
        pid="${proc#/proc/}"; pid="${pid%/exe}"
        if is_game_pid "$pid"; then printf '%s\n' "$pid"; fi
    done
}
game_status() {
    local pids
    pids="$(game_pids)"
    info Project "${TD_PROJECT_DIR##*/}/"
    if [[ -x "$TD_GAME" ]]; then
        info Build "$TD_GAME"
        info Modified "$(date -r "$TD_GAME" '+%Y-%m-%d %H:%M:%S %Z')"
    else
        info Build 'Missing; run ./build.sh linux first.'
    fi
    info Profile "$TD_PROFILE"
    info Logs "$TD_ROOT/logs/game.log (engine), $TD_ROOT/logs/console.log (console)"
    if [[ -n "$pids" ]]; then
        info State "Running; PID(s): ${pids//$'\n'/, }"
        ps -p "${pids//$'\n'/,}" -o pid,etime,rss,comm || true
    else
        info State 'Stopped'
    fi
}
