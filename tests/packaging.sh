#!/usr/bin/env bash
set -euo pipefail
td_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
td_project="$(dirname -- "$td_repo")"
cd -- "$td_project"
td_repo=repo
mkdir -p tmp
td_suite="$(mktemp -d "tmp/packaging-tests.XXXXXXXX")"
td_real_mv="$(command -v mv)"
td_count=0
trap 'printf "Packaging fixtures: %s\n" "$td_suite"' EXIT
new_fixture() {
    td_fixture="$td_suite/$1 with spaces"
    mkdir -p "$td_fixture/repo/packaging" "$td_fixture/tools/templates" "$td_fixture/run/linux" "$td_fixture/run/launchers" "$td_fixture/.config"
    for file in common.sh build.sh start.sh stop.sh runtime-files.txt export_notices.gd inputs.sh; do cp "$td_repo/packaging/$file" "$td_fixture/repo/packaging/$file"; done
    cp "$td_repo/VERSION" "$td_fixture/repo/VERSION"
    while IFS= read -r file; do
        [[ -z "$file" || "$file" == \#* ]] && continue
        mkdir -p "$td_fixture/repo/$(dirname -- "$file")"
        cp "$td_repo/$file" "$td_fixture/repo/$file"
    done < "$td_repo/packaging/runtime-files.txt"
    printf 'previous-game\n' > "$td_fixture/run/linux/SimpleTowerDefense2D.x86_64"
    printf 'previous-launcher\n' > "$td_fixture/run/launchers/sentinel"
    printf 'private-profile\n' > "$td_fixture/.config/sentinel"
    touch "$td_fixture/tools/templates/linux_release.x86_64"
    cat > "$td_fixture/tools/godot" <<'ENGINE'
#!/usr/bin/env bash
set -eu
if [[ "$1" == --version ]]; then printf '4.6.2.stable.test\n'; exit 0; fi
project=.
while (( $# )); do
    case "$1" in
        --path) project="$2"; shift 2 ;;
        --script)
            printf 'Godot Engine license fixture\n' > "$project/$4"
            exit 0 ;;
        --import)
            if [[ "${TD_TEST_MODE:-}" == import-error ]]; then printf 'SCRIPT ERROR: injected import failure\n'; fi
            exit 0 ;;
        --export-release)
            case "${TD_TEST_MODE:-}" in
                export-failure) exit 42 ;;
                missing-output) exit 0 ;;
            esac
            output="$3"
            [[ "$output" == /* ]] || output="$project/$output"
            printf 'new-game\n' > "$output"
            chmod +x "$output"
            if [[ "${TD_TEST_MODE:-}" == source-change ]]; then printf '\n# changed during export\n' >> repo/project.godot; fi
            printf '\033[32mfixture export\033[0m\n'
            exit 0 ;;
        *) shift ;;
    esac
done
exit 3
ENGINE
    cat > "$td_fixture/tools/mv" <<'MOVE'
#!/usr/bin/env bash
set -eu
source_path="${@: -2:1}"
if [[ "${TD_TEST_MODE:-}" == publish-failure && "$source_path" == */tmp/build-*/launchers ]]; then
    exit 44
fi
exec "$TD_TEST_REAL_MV" "$@"
MOVE
    chmod +x "$td_fixture/tools/godot" "$td_fixture/tools/mv"
}
run_build() {
    (
        cd -- "$td_fixture"
        env GODOT_BIN=tools/godot GODOT_TEMPLATE_DIR=tools/templates \
            TD_TEST_MODE="${td_mode:-}" TD_TEST_REAL_MV="$td_real_mv" PATH="$PWD/tools:$PATH" \
            bash repo/packaging/build.sh --plain "$@"
    ) >"$td_fixture/result.log" 2>&1
}
old_preserved() {
    [[ "$(cat "$td_fixture/run/linux/SimpleTowerDefense2D.x86_64")" == previous-game ]]
    [[ "$(cat "$td_fixture/run/launchers/sentinel")" == previous-launcher ]]
    [[ "$(cat "$td_fixture/.config/sentinel")" == private-profile ]]
}
expect_failure() {
    if run_build "$@"; then cat "$td_fixture/result.log"; printf 'Expected build rejection\n' >&2; exit 1; fi
    old_preserved
    td_count=$((td_count + 1))
}
new_fixture success
td_mode=ok
run_build
[[ "$(cat "$td_fixture/run/linux/SimpleTowerDefense2D.x86_64")" == new-game ]]
[[ "$(cat "$td_fixture/.config/sentinel")" == private-profile ]]
[[ -f "$td_fixture/run/launchers/start.sh" ]]
[[ -f "$td_fixture/run/linux/LICENSE" ]]
[[ -s "$td_fixture/run/linux/THIRD_PARTY_NOTICES.txt" ]]
if grep -q $'\033' "$td_fixture/result.log"; then printf 'Plain build emitted ANSI escapes\n' >&2; exit 1; fi
[[ ! -e "$td_fixture/repo/.godot" ]]
# The complete source/build setup must survive a rename, with no old directory.
td_original="$td_fixture"
mv -- "$td_fixture" "$td_suite/renamed project with spaces"
td_fixture="$td_suite/renamed project with spaces"
run_build
[[ ! -e "$td_original" ]]
if grep -Fq "$td_project/" "$td_fixture/result.log"; then printf 'Build output leaked the full project path\n' >&2; exit 1; fi
td_count=$((td_count + 1))
mv "$td_fixture/repo" "$td_fixture/source-away"
"$td_fixture/start.sh" --status --plain > "$td_fixture/status.log"
grep -Fq './run/linux/' "$td_fixture/status.log"
if grep -Fq "$td_project/" "$td_fixture/status.log"; then printf 'Status output leaked the full project path\n' >&2; exit 1; fi
td_count=$((td_count + 1))
for td_mode in import-error export-failure missing-output publish-failure source-change; do
    new_fixture "$td_mode"
    expect_failure
    while IFS= read -r -d '' link; do
        [[ "$(readlink -- "$link")" != /* ]]
    done < <(find "$td_fixture/tmp" -type l -print0)
done
td_mode=ok
new_fixture duplicate-manifest
printf 'project.godot\n' >> "$td_fixture/repo/packaging/runtime-files.txt"
expect_failure --check
new_fixture missing-required
sed -i '/^LICENSE$/d' "$td_fixture/repo/packaging/runtime-files.txt"
expect_failure --check
new_fixture linked-source
mv "$td_fixture/repo/project.godot" "$td_fixture/project.godot"
ln -s ../project.godot "$td_fixture/repo/project.godot"
expect_failure --check
new_fixture linked-log
mkdir "$td_fixture/logs"
ln -s ../.config/sentinel "$td_fixture/logs/build-linux.log"
expect_failure --check
new_fixture linked-output
mv "$td_fixture/run/linux" "$td_fixture/run/saved-linux"
ln -s saved-linux "$td_fixture/run/linux"
expect_failure --check
new_fixture linked-runtime
mv "$td_fixture/run" "$td_fixture/saved-run"
ln -s saved-run "$td_fixture/run"
expect_failure --check
new_fixture invalid-target
expect_failure invalid
printf 'Packaging scenarios: %d passed\n' "$td_count"
