#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "check_docker dies with an actionable message if docker is missing" {
    # Use an isolated empty directory for PATH to robustly ensure docker is not found,
    # regardless of this environment's docker installation location.
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path"
    mkdir -p "$empty_path_dir"
    local original_path="$PATH"
    export PATH="$empty_path_dir"
    source bundle/install.sh
    run check_docker
    export PATH="$original_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker"* ]]
}

@test "check_docker passes when docker is present and the daemon responds" {
    stub_docker
    source bundle/install.sh
    run check_docker
    [ "$status" -eq 0 ]
}

@test "check_disk_space dies with an actionable message when space is insufficient" {
    source bundle/install.sh
    MIN_FREE_MB=999999999
    run check_disk_space "$BATS_TEST_TMPDIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MB free"* ]]
}

@test "check_disk_space passes when space is sufficient" {
    source bundle/install.sh
    MIN_FREE_MB=1
    run check_disk_space "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}
