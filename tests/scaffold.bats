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

@test "stub_curl intercepts curl and logs its arguments" {
    stub_curl
    run curl -fsSk https://example.invalid/
    [ "$status" -eq 0 ]
    grep -q "^-fsSk https://example.invalid/$" "$CURL_LOG"
    unstub_curl
}
