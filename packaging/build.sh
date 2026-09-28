#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
td_target=linux td_check=false td_target_set=false
for arg in "$@"; do
    case "$arg" in
        --plain) ;;
        --check) td_check=true ;;
        linux|windows|web|macos|all|release)
            "$td_target_set" && fail 'Choose one export target per build.'
            td_target="$arg"; td_target_set=true ;;
        --help|-h)
            printf 'Usage: build.sh [linux|windows|web|macos|all|release] [--check] [--plain]\nDefault: linux. release builds all targets and packages a clean committed version.\n--check validates inputs/tools without exporting. No downloads or game launch.\nSet GODOT_BIN and GODOT_TEMPLATE_DIR to select installed build tools.\n'
            exit 0 ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
if [[ "$td_target" == all || "$td_target" == release ]]; then
    td_flags=()
    [[ -n "$TD_COLOR" ]] || td_flags+=(--plain)
    "$td_check" && td_flags+=(--check)
    for td_platform in linux windows web macos; do
        bash repo/packaging/build.sh "$td_platform" "${td_flags[@]}"
    done
    if [[ "$td_target" == release ]] && ! "$td_check"; then
        bash repo/packaging/package.sh "${td_flags[@]}"
    fi
    exit 0
fi
td_source="$TD_ROOT/repo"
td_manifest="$td_source/packaging/runtime-files.txt"
validate_project_paths
require_local_path "$td_source"
require_local_path "$td_manifest"
require_local_path "$td_source/packaging/inputs.sh"
source "$td_source/packaging/inputs.sh"
[[ -f "$td_manifest" ]] || fail 'Expected source checkout in repo/ with packaging/runtime-files.txt.'
require_local_path "$td_source/VERSION"
td_release="$(cat "$td_source/VERSION")"
[[ "$td_release" =~ ^v[1-9][0-9]*$ ]] || fail 'Invalid release version in VERSION.'
grep -Fqx "const VERSION := \"$td_release\"" "$td_source/scripts/game_rules.gd" || fail 'VERSION and game version differ.'
grep -Fqx "config/version=\"${td_release#v}.0.0\"" "$td_source/project.godot" || fail 'VERSION and project version differ.'
require_local_path "$td_source/packaging/export_notices.gd"
[[ -f "$td_source/packaging/export_notices.gd" ]] || fail 'Missing license-notice export helper.'
td_files=()
declare -A td_seen=()
while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    case "$entry" in /*|../*|*/../*|*/..|.|..|*\\*) fail "Unsafe manifest entry: $entry" ;; esac
    [[ -f "$td_source/$entry" && ! -L "$td_source/$entry" ]] || fail "Missing or symlinked input: $entry"
    require_local_path "$td_source/$entry"
    [[ -z "${td_seen[$entry]:-}" ]] || fail "Duplicate manifest entry: $entry"
    td_seen["$entry"]=1
    td_files+=("$entry")
done < "$td_manifest"
(( ${#td_files[@]} > 0 )) || fail 'The runtime manifest is empty.'
for entry in LICENSE project.godot export_presets.cfg scenes/main.tscn; do
    [[ -n "${td_seen[$entry]:-}" ]] || fail "Required manifest entry missing: $entry"
done
for launcher in common.sh start.sh stop.sh; do
    require_local_path "$td_source/packaging/$launcher"
    [[ -f "$td_source/packaging/$launcher" && ! -L "$td_source/packaging/$launcher" ]] || fail "Missing launcher: $launcher"
done
bash -n "$td_source/packaging/common.sh" "$td_source/packaging/start.sh" "$td_source/packaging/stop.sh"
for tool in flock mktemp cp install mv ln tee sed grep sha256sum cut find sort xargs; do
    command -v "$tool" >/dev/null || fail "Required build utility missing: $tool"
done
td_engine="${GODOT_BIN:-}"
if [[ -z "$td_engine" ]]; then td_engine="$(command -v godot4 || command -v godot || true)"; fi
[[ -n "$td_engine" ]] || fail 'Godot 4.6 is required; set GODOT_BIN to an installed binary.'
td_engine="$(command -v -- "$td_engine")" || fail 'GODOT_BIN is not executable.'
td_engine="$(readlink -f -- "$td_engine")"
td_version="$("$td_engine" --version)"
[[ "$td_version" == 4.6.* ]] || fail "This project expects Godot 4.6; found $td_version."
IFS=. read -r td_major td_minor td_patch td_channel _ <<< "$td_version"
td_template_version="$td_major.$td_minor.$td_patch.$td_channel"
td_templates="${GODOT_TEMPLATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/$td_template_version}"
td_templates="$(readlink -m -- "$td_templates")"
case "$td_target" in
    linux) td_preset='Linux'; td_folder=linux; td_output=SimpleTowerDefense2D.x86_64; td_template=linux_release.x86_64 ;;
    windows) td_preset='Windows Desktop'; td_folder=win; td_output=SimpleTowerDefense2D.exe; td_template=windows_release_x86_64.exe ;;
    web) td_preset='Web'; td_folder=web; td_output=index.html; td_template=web_nothreads_release.zip ;;
    macos) td_preset='macOS'; td_folder=osx; td_output=SimpleTowerDefense2D.zip; td_template=macos.zip ;;
esac
td_destination="$TD_ROOT/run/$td_folder"
require_local_path "$td_destination"
for td_log in "build-$td_target.log" "import-$td_target.log" "export-$td_target.log" "notices-$td_target.log" "import-$td_target-console.log" "export-$td_target-console.log" "notices-$td_target-console.log"; do
    require_local_path "$TD_ROOT/logs/$td_log"
done
for launcher in start.sh stop.sh build.sh; do
    td_link="run/launchers/$launcher"
    [[ "$launcher" != build.sh ]] || td_link=repo/packaging/build.sh
    if [[ -e "$TD_ROOT/$launcher" || -L "$TD_ROOT/$launcher" ]]; then
        [[ -L "$TD_ROOT/$launcher" && "$(readlink -- "$TD_ROOT/$launcher")" == "$td_link" ]] \
            || fail "Existing root entrypoint is not the expected relative link: $launcher"
    fi
done
[[ -f "$td_templates/$td_template" ]] || fail "Missing installed template $td_template for Godot $td_template_version; check GODOT_TEMPLATE_DIR."
info Godot "$td_version"
info Release "$td_release"
info Templates "$td_template_version (installed Godot toolchain)"
info Manifest "${#td_files[@]} explicit project files; 3 runtime launcher files"
info Target "$td_preset -> run/$td_folder/$td_output"
info Logs "$TD_ROOT/logs/build-$td_target.log"
if "$td_check"; then info Check 'Passed; no export or game launch performed'; exit 0; fi
td_input_digest="$(build_input_digest)"
td_source_revision=unversioned td_source_state=unversioned
if [[ -e "$td_source/.git" ]]; then
    td_source_revision="$(git -C "$td_source" rev-parse HEAD)"
    td_source_state=clean
    [[ -z "$(git -C "$td_source" status --porcelain)" ]] || td_source_state=dirty
fi
project_environment
exec 9>"$TD_ROOT/tmp/lifecycle.lock"
flock -n 9 || fail 'Another launch, stop, or build is in progress.'
[[ -z "$(game_pids)" ]] || fail 'The game is running; close it before rebuilding.'
td_stage="$(mktemp -d "$TD_ROOT/tmp/build-$td_target.XXXXXXXX")"
td_backup='' td_previous_game=false td_previous_launchers=false
td_published_game=false td_published_launchers=false td_committed=false
td_created_links=()
finish_build() {
    local status=$?
    trap - EXIT HUP INT TERM
    if ! "$td_committed"; then
        set +e
        # Retain the failed new files, then restore both prior deployment parts.
        if "$td_published_launchers"; then mv -T -- "$TD_ROOT/run/launchers" "$td_stage/failed-launchers"; fi
        if "$td_previous_launchers"; then mv -T -- "$td_backup/launchers" "$TD_ROOT/run/launchers"; fi
        if "$td_published_game"; then mv -T -- "$td_destination" "$td_stage/failed-export"; fi
        if "$td_previous_game"; then mv -T -- "$td_backup/$td_folder" "$td_destination"; fi
        for launcher in "${td_created_links[@]}"; do rm -- "$TD_ROOT/$launcher"; done
        info Staging "Build not published; inspect $td_stage"
    fi
    exit "$status"
}
trap finish_build EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p -- "$td_stage/project" "$td_stage/output" "$td_stage/launchers" "$td_stage/data/godot/export_templates"
for entry in "${td_files[@]}"; do
    mkdir -p -- "$td_stage/project/$(dirname -- "$entry")"
    cp -- "$td_source/$entry" "$td_stage/project/$entry"
done
for launcher in common.sh start.sh stop.sh; do
    install -m 755 -- "$td_source/packaging/$launcher" "$td_stage/launchers/$launcher"
done
ln -sr -- "$td_templates" "$td_stage/data/godot/export_templates/$td_template_version"
# Editor writes and import caches stay in staging, away from source and profiles.
export XDG_DATA_HOME="$TD_PROJECT_DIR/${td_stage#./}/data" XDG_CONFIG_HOME="$TD_PROJECT_DIR/${td_stage#./}/config"
: > "$TD_ROOT/logs/build-$td_target.log"
run_engine_step() {
    local phase="$1"; shift
    local transcript="$TD_ROOT/logs/$phase-$td_target-console.log"
    info Step "$phase ($td_preset)"
    if ! "$td_engine" --headless --path "$td_stage/project" --log-file "../../../logs/$phase-$td_target.log" "$@" \
        2>&1 | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | tee "$transcript" | tee -a "$TD_ROOT/logs/build-$td_target.log"; then
        fail "Godot $phase failed; previous deployment retained."
    fi
    # Godot can print script/import errors while returning success.
    if grep -Eq '(^|[[:space:]])(SCRIPT ERROR:|ERROR:|Parse Error:)' "$transcript"; then
        fail "Godot $phase reported errors; previous deployment retained."
    fi
}
run_engine_step import --import
cp -- "$td_source/packaging/export_notices.gd" "$td_stage/project/export_notices.gd"
run_engine_step notices --script res://export_notices.gd -- ../output/THIRD_PARTY_NOTICES.txt
[[ -s "$td_stage/output/THIRD_PARTY_NOTICES.txt" ]] || fail 'Engine license notices were not generated.'
rm -- "$td_stage/project/export_notices.gd"
if [[ -f "$td_stage/project/export_notices.gd.uid" ]]; then rm -- "$td_stage/project/export_notices.gd.uid"; fi
run_engine_step export --export-release "$td_preset" "../output/$td_output"
[[ -s "$td_stage/output/$td_output" ]] || fail 'Export did not produce the expected output.'
cp -- "$td_stage/project/LICENSE" "$td_stage/output/LICENSE"
printf '%s\n' "$td_release" > "$td_stage/output/VERSION"
printf 'VERSION %s\nCOMMIT %s\nWORKTREE %s\nSOURCE_SHA256 %s\nGODOT %s\n' \
    "$td_release" "$td_source_revision" "$td_source_state" "$td_input_digest" "$td_version" > "$td_stage/output/BUILD_INFO.txt"
(cd "$td_stage/output" && find . -type f ! -path './EXPORT_SHA256' -print0 | sort -z | xargs -0 sha256sum > EXPORT_SHA256)
[[ "$(build_input_digest)" == "$td_input_digest" ]] || fail 'Source changed during the build; export not published.'
validate_project_paths
require_local_path "$td_destination"
mkdir -p -- "$TD_ROOT/.cache/build-backups"
td_backup="$(mktemp -d "$TD_ROOT/.cache/build-backups/$td_folder.XXXXXXXX")"
if [[ -e "$td_destination" ]]; then
    mv -T -- "$td_destination" "$td_backup/$td_folder"
    td_previous_game=true
fi
if [[ -e "$TD_ROOT/run/launchers" ]]; then
    mv -T -- "$TD_ROOT/run/launchers" "$td_backup/launchers"
    td_previous_launchers=true
fi
mv -T -- "$td_stage/output" "$td_destination"
td_published_game=true
mv -T -- "$td_stage/launchers" "$TD_ROOT/run/launchers"
td_published_launchers=true
for launcher in start.sh stop.sh; do
    if [[ ! -e "$TD_ROOT/$launcher" && ! -L "$TD_ROOT/$launcher" ]]; then
        ln -s -- "run/launchers/$launcher" "$TD_ROOT/$launcher"
        td_created_links+=("$launcher")
    fi
done
if [[ ! -e "$TD_ROOT/build.sh" && ! -L "$TD_ROOT/build.sh" ]]; then
    ln -s -- repo/packaging/build.sh "$TD_ROOT/build.sh"
    td_created_links+=(build.sh)
fi
td_committed=true
cd -- "$TD_ROOT"
rm -rf -- "$td_stage"
trap - EXIT HUP INT TERM
info Built "$td_destination/$td_output"
info Previous "$td_backup"
info State 'Export complete; game not started. Profiles and other platform builds preserved.'
