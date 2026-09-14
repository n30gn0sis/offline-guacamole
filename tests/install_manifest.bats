#!/usr/bin/env bats

load 'test_helper'

setup() {
    export ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/images"
    echo "abc" > "$ROOT/images/guacamole.tar"
    (cd "$ROOT" && sha256sum images/guacamole.tar > manifest.sha256)
}

@test "verify_manifest passes when every file matches its checksum" {
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -eq 0 ]
}

@test "verify_manifest dies and names the file when a checksum mismatches" {
    echo "tampered" > "$ROOT/images/guacamole.tar"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"guacamole.tar"* ]]
}

@test "verify_manifest dies with an actionable message when manifest.sha256 is missing" {
    rm "$ROOT/manifest.sha256"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest.sha256"* ]]
}
