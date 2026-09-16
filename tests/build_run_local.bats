#!/usr/bin/env bats

# --run-local stages bundle/ into a temp tree and brings it up with docker
# compose, without saving images or producing a tarball. These tests drive
# run_local against the stubbed docker (schema generation and compose are
# faked; openssl is real) and assert on what was invoked, what existed at
# the moment `up` ran, and what was left behind.

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'VERS'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
VERS
    export BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE_DIR/nginx"
    cat > "$BUNDLE_DIR/docker-compose.yml" <<'YML'
services:
  postgres:
    image: __POSTGRES_IMAGE_REF__
  guacd:
    image: __GUACD_IMAGE_REF__
  guacamole:
    image: __GUACAMOLE_IMAGE_REF__
  nginx:
    image: __NGINX_IMAGE_REF__
YML
    printf 'POSTGRES_DB=guacamole_db\nPOSTGRES_USER=guacamole\nPOSTGRES_PASSWORD=__POSTGRES_PASSWORD__\n' \
        > "$BUNDLE_DIR/env.template"
    echo "install" > "$BUNDLE_DIR/install.sh"
    export DIST_DIR="$BATS_TEST_TMPDIR/dist"
    # Confine mktemp so the tests can prove the staged tree was removed.
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    # Where the docker stub records the cwd and a snapshot of the staged tree
    # at the moment `compose up` runs.
    export UP_STATE="$BATS_TEST_TMPDIR/up_state"
}

teardown() {
    unstub_docker
}

# `docker run` prints a schema; `docker compose ... up` records its cwd and
# which generated files existed at that instant, then exits with $UP_RC.
write_run_local_stub() {
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'STUB'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
elif [[ "$1" == "compose" && " $* " == *" up "* ]]; then
    {
        printf 'cwd=%s\n' "$PWD"
        [[ -f .env ]] && printf 'env=present\n'
        [[ -f nginx/certs/fullchain.pem && -f nginx/certs/privkey.pem ]] && printf 'certs=present\n'
        printf 'env_mode=%s\n' "$(stat -c %a .env 2>/dev/null)"
        grep -q '__POSTGRES_PASSWORD__' .env 2>/dev/null && printf 'env=unsubstituted\n'
        grep -q '__[A-Z]*_IMAGE_REF__' docker-compose.yml && printf 'compose=unsubstituted\n'
        [[ -s initdb/001-schema.sql ]] && printf 'schema=present\n'
    } > "$UP_STATE"
    exit "${UP_RC:-0}"
fi
exit 0
STUB
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
}

@test "run_local brings the staged tree up with compose --wait and never saves images" {
    stub_docker
    write_run_local_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { :; }
    run run_local
    [ "$status" -eq 0 ]
    grep -q "^compose --env-file .env up -d --wait --wait-timeout 180$" "$DOCKER_LOG"
    ! grep -q "^save" "$DOCKER_LOG"
    grep -q "^cwd=${TMPDIR}/guac-runlocal\.[A-Za-z0-9]*/guacamole-offline-1.6.0$" "$UP_STATE"
    [[ "$output" == *"Run-local passed"* ]]
}

@test "run_local has generated .env (mode 600), TLS certs, schema and a concrete compose file before up runs" {
    stub_docker
    write_run_local_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { :; }
    run run_local
    [ "$status" -eq 0 ]
    grep -q '^env=present$' "$UP_STATE"
    grep -q '^env_mode=600$' "$UP_STATE"
    grep -q '^certs=present$' "$UP_STATE"
    grep -q '^schema=present$' "$UP_STATE"
    ! grep -q 'unsubstituted' "$UP_STATE"
}

@test "run_local tears the stack down and removes the staged tree after success" {
    stub_docker
    write_run_local_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { :; }
    run run_local
    [ "$status" -eq 0 ]
    grep -q "^compose --env-file .env down -v$" "$DOCKER_LOG"
    # `down` must come after `up`.
    up_line="$(grep -n ' up ' "$DOCKER_LOG" | cut -d: -f1)"
    down_line="$(grep -n ' down ' "$DOCKER_LOG" | cut -d: -f1)"
    [ "$down_line" -gt "$up_line" ]
    [ -z "$(ls -d "$TMPDIR"/guac-runlocal.* 2>/dev/null)" ]
}

@test "run_local dies with diagnostics, still tears down, and leaves no dist/ when the stack does not come up" {
    stub_docker
    write_run_local_stub
    export UP_RC=1
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { die "verify must not run when up failed"; }
    run run_local
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not come up healthy"* ]]
    [[ "$output" != *"verify must not run"* ]]
    grep -q "^compose --env-file .env ps$" "$DOCKER_LOG"
    grep -q "^compose --env-file .env logs --tail=50$" "$DOCKER_LOG"
    grep -q "^compose --env-file .env down -v$" "$DOCKER_LOG"
    [ -z "$(ls -d "$TMPDIR"/guac-runlocal.* 2>/dev/null)" ]
    [ ! -e "$DIST_DIR" ]
}

@test "run_local dies when a probe fails, and still tears down" {
    stub_docker
    write_run_local_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { die "simulated probe failure"; }
    run run_local
    [ "$status" -ne 0 ]
    [[ "$output" == *"simulated probe failure"* ]]
    grep -q "^compose --env-file .env down -v$" "$DOCKER_LOG"
    [ -z "$(ls -d "$TMPDIR"/guac-runlocal.* 2>/dev/null)" ]
}

@test "run_local leaves the source bundle/ untouched" {
    stub_docker
    write_run_local_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { :; }
    run run_local
    [ "$status" -eq 0 ]
    [ ! -e "$BUNDLE_DIR/.env" ]
    [ ! -e "$BUNDLE_DIR/nginx/certs" ]
    [ ! -e "$BUNDLE_DIR/initdb" ]
    grep -q '__POSTGRES_IMAGE_REF__' "$BUNDLE_DIR/docker-compose.yml"
}

@test "run_local dies if env.template is missing from bundle/" {
    stub_docker
    write_run_local_stub
    rm "$BUNDLE_DIR/env.template"
    source build.sh
    load_versions "$VERSIONS_FILE"
    verify_stack_responds() { :; }
    run run_local
    [ "$status" -ne 0 ]
    [[ "$output" == *"env.template not found"* ]]
    ! grep -q ' up ' "$DOCKER_LOG"
}

# --- verify_stack_responds, against a stubbed curl -------------------------

@test "verify_stack_responds passes when the login page answers and an authToken comes back" {
    stub_curl
    cat > "$STUB_BIN_DIR/curl_stub_script.sh" <<'STUB'
if [[ " $* " == *"/api/tokens"* ]]; then
    printf '{"authToken":"abc123","username":"guacadmin"}'
fi
exit 0
STUB
    export CURL_STUB_SCRIPT="$STUB_BIN_DIR/curl_stub_script.sh"
    source build.sh
    run verify_stack_responds Run-local
    [ "$status" -eq 0 ]
    grep -q "^-fsSk https://127.0.0.1/guacamole/$" "$CURL_LOG"
    grep -q "^-fsSk -X POST https://127.0.0.1/guacamole/api/tokens -d username=guacadmin&password=guacadmin$" "$CURL_LOG"
    [[ "$output" == *"Run-local: checking the login page"* ]]
    unstub_curl
}

@test "verify_stack_responds dies, labelled, when the login page does not answer" {
    stub_curl
    cat > "$STUB_BIN_DIR/curl_stub_script.sh" <<'STUB'
exit 22
STUB
    export CURL_STUB_SCRIPT="$STUB_BIN_DIR/curl_stub_script.sh"
    source build.sh
    run verify_stack_responds Run-local
    [ "$status" -ne 0 ]
    [[ "$output" == *"Run-local failed: login page did not respond"* ]]
    unstub_curl
}

@test "verify_stack_responds dies when no authToken is returned" {
    stub_curl
    cat > "$STUB_BIN_DIR/curl_stub_script.sh" <<'STUB'
if [[ " $* " == *"/api/tokens"* ]]; then
    printf '{"message":"Invalid login"}'
fi
exit 0
STUB
    export CURL_STUB_SCRIPT="$STUB_BIN_DIR/curl_stub_script.sh"
    source build.sh
    run verify_stack_responds Selftest
    [ "$status" -ne 0 ]
    [[ "$output" == *"Selftest failed: could not obtain an authToken"* ]]
    unstub_curl
}

# --- the --run-local flag in main ------------------------------------------
# Driven through a real bash subprocess, as in build_selftest.bats, with the
# expensive steps overridden to leave markers.

write_driver() {
    local path="$1"
    cat > "$path" <<DRV
#!/usr/bin/env bash
set -euo pipefail
source "$BATS_TEST_DIRNAME/../build.sh"
load_versions()  { GUACAMOLE_TAG=1.6.0; }
pull_images()    { echo "MARK pull_images" >&2; }
package_bundle() { echo "MARK package_bundle" >&2; printf '%s\n' "/nonexistent.tar.gz"; }
run_selftest()   { echo "MARK run_selftest" >&2; }
run_local()      { echo "MARK run_local" >&2; }
main "\$@"
DRV
}

@test "--run-local pulls, runs locally, and never packages" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh" --run-local
    [ "$status" -eq 0 ]
    [[ "$output" == *"MARK pull_images"* ]]
    [[ "$output" == *"MARK run_local"* ]]
    [[ "$output" != *"MARK package_bundle"* ]]
    [[ "$output" != *"MARK run_selftest"* ]]
}

# Marker line numbers in $output, so ordering can be asserted.
mark_line() { printf '%s\n' "$output" | grep -n "MARK $1" | head -1 | cut -d: -f1; }

@test "a plain build runs the local check before packaging" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MARK run_local"* ]]
    [[ "$output" == *"MARK package_bundle"* ]]
    [ "$(mark_line run_local)" -lt "$(mark_line package_bundle)" ]
    [[ "$output" != *"MARK run_selftest"* ]]
}

@test "--no-run-local skips the local check and packages" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh" --no-run-local
    [ "$status" -eq 0 ]
    [[ "$output" == *"Skipping the local pre-package check"* ]]
    [[ "$output" != *"MARK run_local"* ]]
    [[ "$output" == *"MARK package_bundle"* ]]
}

@test "a failing local check aborts the build before packaging" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    # Override after the driver's own stub: die inside a subshell, as the
    # real run_local does.
    sed -i 's|^run_local()      .*|run_local()      { ( die "simulated local failure" ); }|' "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"simulated local failure"* ]]
    [[ "$output" != *"MARK package_bundle"* ]]
}

@test "--selftest runs the local check, then packages, then the selftest" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh" --selftest
    [ "$status" -eq 0 ]
    [ "$(mark_line run_local)" -lt "$(mark_line package_bundle)" ]
    [ "$(mark_line package_bundle)" -lt "$(mark_line run_selftest)" ]
}

@test "--run-local and --no-run-local together are refused before anything runs" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh" --run-local --no-run-local
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    [[ "$output" != *"MARK"* ]]
}

@test "--run-local and --selftest together are refused before anything runs" {
    write_driver "$BATS_TEST_TMPDIR/drive.sh"
    run bash "$BATS_TEST_TMPDIR/drive.sh" --run-local --selftest
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
    [[ "$output" != *"MARK"* ]]
}

@test "--help documents --run-local and --no-run-local" {
    run bash build.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--run-local"* ]]
    [[ "$output" == *"--no-run-local"* ]]
}
