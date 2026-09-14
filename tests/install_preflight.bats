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

@test "check_disk_space dies when df yields no usable value for the path" {
    source bundle/install.sh
    run check_disk_space "$BATS_TEST_TMPDIR/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not determine free disk space"* ]]
}

@test "check_openssl dies with an actionable message if openssl is missing" {
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path"
    mkdir -p "$empty_path_dir"
    source bundle/install.sh
    local original_path="$PATH"
    export PATH="$empty_path_dir"
    run check_openssl
    export PATH="$original_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"openssl"* ]]
    [[ "$output" == *"install"* ]]
}

@test "check_openssl passes when openssl is present" {
    source bundle/install.sh
    run check_openssl
    [ "$status" -eq 0 ]
}

@test "check_ports_free reports that it skipped the check when ss is unavailable" {
    empty_path_dir="$BATS_TEST_TMPDIR/empty_path_ss"
    mkdir -p "$empty_path_dir"
    source bundle/install.sh
    local original_path="$PATH"
    export PATH="$empty_path_dir"
    run check_ports_free
    export PATH="$original_path"
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping"* ]]
    [[ "$output" == *"80/443"* ]]
}

@test "preflight_checks checks free space under the Docker data root, not the bundle dir" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$*" == "info --format {{.DockerRootDir}}" ]]; then
    echo "/var/lib/docker-test-root"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source bundle/install.sh
    # Observe what path check_disk_space is handed, without needing that path
    # to exist on this machine.
    check_disk_space() { printf 'CHECKED:%s\n' "$1" >&2; }
    run preflight_checks
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHECKED:/var/lib/docker-test-root"* ]]
    [[ "$output" != *"CHECKED:${SCRIPT_DIR}"* ]]
}

@test "preflight_checks dies if the Docker data root cannot be determined" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$*" == "info --format {{.DockerRootDir}}" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source bundle/install.sh
    run preflight_checks
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker data root"* ]]
}
