#!/usr/bin/env bash
# Called from the project root. Hash only declared build inputs, using relative
# names so a moved checkout produces the same fingerprint.
build_input_digest() (
    cd repo
    {
        sha256sum VERSION packaging/runtime-files.txt packaging/build.sh packaging/common.sh \
            packaging/start.sh packaging/stop.sh packaging/export_notices.gd packaging/inputs.sh
        while IFS= read -r entry; do
            [[ -z "$entry" || "$entry" == \#* ]] && continue
            sha256sum -- "$entry"
        done < packaging/runtime-files.txt
    } | sha256sum | cut -d ' ' -f 1
)
