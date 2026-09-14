#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
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
