#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "stub_docker intercepts docker and logs its arguments" {
    stub_docker
    run docker pull hello:world
    [ "$status" -eq 0 ]
    grep -q "pull hello:world" "$DOCKER_LOG"
}
