#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/common.sh"
validate_project_paths
require_local_path repo/packaging/inputs.sh
source repo/packaging/inputs.sh
for arg in "$@"; do
    case "$arg" in
        --plain) ;;
        --help|-h) printf 'Usage: package.sh [--plain]\nPackage matching, clean committed exports into run/releases/<version>/.\n'; exit 0 ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
for tool in zip unzip sha256sum git; do command -v "$tool" >/dev/null || fail "Missing packaging tool: $tool"; done
validate_project_paths
for path in run/releases .cache/release-backups; do require_local_path "$path"; done
td_version="$(cat repo/VERSION)"
[[ "$td_version" =~ ^v[1-9][0-9]*$ ]] || fail 'Invalid VERSION.'
[[ -z "$(git -C repo status --porcelain)" ]] || fail 'Commit the reviewed source before packaging a release.'
td_commit="$(git -C repo rev-parse HEAD)"
td_digest="$(build_input_digest)"
for platform in linux win web osx; do
    require_local_path "run/$platform"
    for file in VERSION BUILD_INFO.txt LICENSE THIRD_PARTY_NOTICES.txt EXPORT_SHA256; do
        require_local_path "run/$platform/$file"
        [[ -s "run/$platform/$file" ]] || fail "Missing run/$platform/$file; rebuild $platform."
    done
    [[ "$(cat "run/$platform/VERSION")" == "$td_version" ]] || fail "Stale $platform version."
    grep -Fqx "COMMIT $td_commit" "run/$platform/BUILD_INFO.txt" || fail "Stale $platform commit; rebuild."
    grep -Fqx 'WORKTREE clean' "run/$platform/BUILD_INFO.txt" || fail "The $platform export was built from uncommitted source."
    grep -Fqx "SOURCE_SHA256 $td_digest" "run/$platform/BUILD_INFO.txt" || fail "Stale $platform source; rebuild."
    (cd "run/$platform" && sha256sum -c --quiet EXPORT_SHA256) || fail "The $platform export changed after building."
done
project_environment
exec 9>tmp/lifecycle.lock
flock -n 9 || fail 'Another launch, stop, build or packaging operation is active.'
td_stage="$(mktemp -d tmp/release-package.XXXXXXXX)"
trap 'info Staging "Packaging stopped; inspect $td_stage"' EXIT
mkdir -p "$td_stage/archives" "$td_stage/linux/SimpleTowerDefense2D/run/linux" \
    "$td_stage/linux/SimpleTowerDefense2D/run/launchers" "$td_stage/win/SimpleTowerDefense2D" \
    "$td_stage/web" "$td_stage/osx"
copy_file() {
    require_local_path "$1"
    [[ -f "$1" ]] || fail "Missing package input: $1"
    cp -p -- "$1" "$2"
}
copy_file run/linux/SimpleTowerDefense2D.x86_64 "$td_stage/linux/SimpleTowerDefense2D/run/linux/"
for file in common.sh start.sh stop.sh; do
    cmp -s "repo/packaging/$file" "run/launchers/$file" || fail 'Runtime launchers differ from committed source.'
    copy_file "run/launchers/$file" "$td_stage/linux/SimpleTowerDefense2D/run/launchers/"
done
ln -s run/launchers/start.sh "$td_stage/linux/SimpleTowerDefense2D/start.sh"
ln -s run/launchers/stop.sh "$td_stage/linux/SimpleTowerDefense2D/stop.sh"
copy_file run/win/SimpleTowerDefense2D.exe "$td_stage/win/SimpleTowerDefense2D/"
if [[ -f run/win/SimpleTowerDefense2D.console.exe ]]; then
    copy_file run/win/SimpleTowerDefense2D.console.exe "$td_stage/win/SimpleTowerDefense2D/"
fi
for file in index.html index.js index.wasm index.pck index.audio.worklet.js index.audio.position.worklet.js index.png index.icon.png index.apple-touch-icon.png; do
    copy_file "run/web/$file" "$td_stage/web/"
done
require_local_path run/osx/SimpleTowerDefense2D.zip
unzip -Z1 run/osx/SimpleTowerDefense2D.zip > "$td_stage/macos-entries.txt"
if grep -Eq '(^/|(^|/)\.\.(/|$)|\\)' "$td_stage/macos-entries.txt"; then
    fail 'Unsafe path in generated macOS archive.'
fi
unzip -q run/osx/SimpleTowerDefense2D.zip -d "$td_stage/osx"
for platform in linux win web osx; do
    destination="$td_stage/$platform"
    [[ "$platform" != linux && "$platform" != win ]] || destination="$destination/SimpleTowerDefense2D"
    for file in LICENSE THIRD_PARTY_NOTICES.txt VERSION BUILD_INFO.txt; do
        copy_file "run/$platform/$file" "$destination/"
    done
    (cd "$td_stage/$platform" && zip -X -q -r -y "../archives/SimpleTowerDefense2D_${platform}_${td_version}.zip" .)
done
(cd "$td_stage/archives" && sha256sum ./*.zip > SHA256SUMS && sha256sum -c SHA256SUMS)
printf 'VERSION %s\nCOMMIT %s\nSOURCE_SHA256 %s\n' "$td_version" "$td_commit" "$td_digest" > "$td_stage/archives/BUILD_INFO.txt"
mkdir -p run/releases .cache/release-backups
require_local_path "run/releases/$td_version"
if [[ -e "run/releases/$td_version" ]]; then
    td_backup="$(mktemp -d ".cache/release-backups/$td_version.XXXXXXXX")"
    mv -T "run/releases/$td_version" "$td_backup/$td_version"
fi
if ! mv -T "$td_stage/archives" "run/releases/$td_version"; then
    [[ -z "${td_backup:-}" ]] || mv -T "$td_backup/$td_version" "run/releases/$td_version"
    fail 'Package publication failed; previous packages restored.'
fi
trap - EXIT
info Release "run/releases/$td_version/ (four archives, checksums and source provenance)"
