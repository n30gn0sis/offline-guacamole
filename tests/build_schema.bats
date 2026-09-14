#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'EOF'
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
EOF
}

teardown() {
    unstub_docker
}

@test "generate_schema runs initdb.sh in the guacamole image and writes 001-schema.sql" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    out_dir="$BATS_TEST_TMPDIR/initdb"
    run generate_schema "$out_dir"
    [ "$status" -eq 0 ]
    [ -s "$out_dir/001-schema.sql" ]
    grep -q "fake schema" "$out_dir/001-schema.sql"
    grep -q "run --rm guacamole/guacamole:1.6.0@sha256:1111" "$DOCKER_LOG"
}

@test "generate_schema dies if the generated file is empty" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run generate_schema "$BATS_TEST_TMPDIR/initdb2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}

@test "generate_schema dies if docker run fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
exit 1
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run generate_schema "$BATS_TEST_TMPDIR/initdb3"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to run initdb.sh"* ]]
}
