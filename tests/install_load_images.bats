#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

setup() {
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    cat > "$COMPOSE_FILE" <<'EOF'
services:
  guacamole:
    image: guacamole/guacamole:1.6.0
  guacd:
    image: guacamole/guacd:1.6.0
EOF
}

@test "load_images loads every tar in IMAGES_DIR" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/images"
    mkdir -p "$IMAGES_DIR"
    touch "$IMAGES_DIR/guacamole.tar" "$IMAGES_DIR/guacd.tar"
    stub_docker
    source bundle/install.sh
    run load_images
    [ "$status" -eq 0 ]
    grep -q "load -i ${IMAGES_DIR}/guacamole.tar" "$DOCKER_LOG"
    grep -q "load -i ${IMAGES_DIR}/guacd.tar" "$DOCKER_LOG"
}

@test "load_images dies with an actionable message when no tars are present" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/empty_images"
    mkdir -p "$IMAGES_DIR"
    stub_docker
    source bundle/install.sh
    run load_images
    [ "$status" -ne 0 ]
    [[ "$output" == *"No image tars found"* ]]
}

@test "load_images dies naming the tar when docker load fails" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/images_bad"
    mkdir -p "$IMAGES_DIR"
    touch "$IMAGES_DIR/guacamole.tar"
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "load" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source bundle/install.sh
    run load_images
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to load image from"* ]]
    [[ "$output" == *"guacamole.tar"* ]]
}

@test "load_images verifies every image the compose file needs now resolves locally" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/images_ok"
    mkdir -p "$IMAGES_DIR"
    touch "$IMAGES_DIR/guacamole.tar"
    stub_docker
    source bundle/install.sh
    run load_images
    [ "$status" -eq 0 ]
    grep -q "image inspect guacamole/guacamole:1.6.0" "$DOCKER_LOG"
    grep -q "image inspect guacamole/guacd:1.6.0" "$DOCKER_LOG"
}

@test "load_images dies naming the image when a compose image did not load" {
    # This is the install-side proof that the build saved the images under
    # names docker compose can actually resolve offline.
    export IMAGES_DIR="$BATS_TEST_TMPDIR/images_missing"
    mkdir -p "$IMAGES_DIR"
    touch "$IMAGES_DIR/guacamole.tar"
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1 $2" == "image inspect" && "$3" == "guacamole/guacd:1.6.0" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source bundle/install.sh
    run load_images
    [ "$status" -ne 0 ]
    [[ "$output" == *"guacamole/guacd:1.6.0"* ]]
    [[ "$output" == *"not present in the local Docker daemon"* ]]
}
