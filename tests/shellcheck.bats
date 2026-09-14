#!/usr/bin/env bats

@test "build.sh is shellcheck-clean" {
    run shellcheck build.sh
    [ "$status" -eq 0 ]
}

@test "bundle/install.sh is shellcheck-clean" {
    run shellcheck bundle/install.sh
    [ "$status" -eq 0 ]
}
