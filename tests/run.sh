#!/usr/bin/env bash
set -euo pipefail
td_repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$td_repo/packaging/common.sh"
td_repo=repo
case "${1:-file-safety}" in
    file-safety) td_test=file-safety; td_script=tests/test_file_safety.gd ;;
    maps) td_test=maps; td_script=test_gen.gd ;;
    release) td_test=release; td_script=tests/test_release.gd ;;
    *) fail 'Usage: tests/run.sh [file-safety|maps|release]' ;;
esac
td_engine="${GODOT_BIN:-$(command -v godot4 || command -v godot || true)}"
[[ -n "$td_engine" ]] || fail 'An installed Godot engine is required.'
td_engine="$(readlink -f -- "$(command -v -- "$td_engine")")"
project_environment
td_stage="$(mktemp -d "$TD_ROOT/tmp/$td_test.XXXXXXXX")"
mkdir -p "$td_stage/project/tests" "$td_stage/data" "$td_stage/config" "$td_stage/tmp"
while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    mkdir -p "$td_stage/project/$(dirname -- "$entry")"
    cp -- "$td_repo/$entry" "$td_stage/project/$entry"
done < "$td_repo/packaging/runtime-files.txt"
cp -- "$td_repo/$td_script" "$td_stage/project/$td_script"
export XDG_DATA_HOME="$TD_PROJECT_DIR/${td_stage#./}/data" XDG_CONFIG_HOME="$TD_PROJECT_DIR/${td_stage#./}/config"
export TMPDIR="$TD_PROJECT_DIR/${td_stage#./}/tmp" TMP="$TD_PROJECT_DIR/${td_stage#./}/tmp" TEMP="$TD_PROJECT_DIR/${td_stage#./}/tmp"
for phase in import tests; do
    if [[ "$phase" == import ]]; then args=(--import); else args=(--script "res://$td_script"); fi
    if ! timeout 30s "$td_engine" --headless --path "$td_stage/project" "${args[@]}" \
        --log-file "../../../logs/$td_test-$phase.log" >"$td_stage/$phase.log" 2>&1; then
        cat "$td_stage/$phase.log"
        fail "$td_test $phase failed; staging retained: $td_stage"
    fi
    if grep -Eq '(SCRIPT ERROR:|ERROR:|Parse Error:)' "$td_stage/$phase.log"; then
        cat "$td_stage/$phase.log"
        fail "Godot reported errors; staging retained: $td_stage"
    fi
done
if [[ "$td_test" == maps ]]; then tail -n 2 "$td_stage/tests.log"; else cat "$td_stage/tests.log"; fi
info Staging "$td_stage (isolated test profile; no game scene launched)"
