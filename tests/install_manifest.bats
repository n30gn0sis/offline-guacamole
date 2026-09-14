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

@test "verify_manifest dies and names a file that was ADDED but not listed" {
    # initdb/ is bind-mounted into Postgres's /docker-entrypoint-initdb.d/ and
    # executed on first boot, so an added file there is a real tamper path
    # that `sha256sum -c` alone cannot see.
    mkdir -p "$ROOT/initdb"
    echo "DROP TABLE guacamole_user;" > "$ROOT/initdb/999-evil.sql"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"999-evil.sql"* ]]
    [[ "$output" == *"NOT listed in manifest.sha256"* ]]
}

@test "verify_manifest tolerates the install-time artifacts that are not in the manifest" {
    # .env and nginx/certs/* are created by install.sh itself after the
    # manifest was written — a re-run must still verify cleanly.
    mkdir -p "$ROOT/nginx/certs"
    echo "POSTGRES_PASSWORD=x" > "$ROOT/.env"
    echo "key" > "$ROOT/nginx/certs/privkey.pem"
    echo "cert" > "$ROOT/nginx/certs/fullchain.pem"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -eq 0 ]
}
