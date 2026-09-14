#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "wait_healthy returns 0 once docker compose ps reports every service healthy" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
args="$*"
case "$args" in
    "compose -f "*" config --services")
        printf 'postgres\nguacd\nguacamole\nnginx\n'
        ;;
    "compose -f "*" ps -q "*)
        echo "fakecontainerid"
        ;;
    "inspect --format "*)
        echo "healthy"
        ;;
esac
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    touch "$COMPOSE_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run wait_healthy 10
    [ "$status" -eq 0 ]
}

@test "wait_healthy times out and reports status when a service never becomes healthy" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
args="$*"
case "$args" in
    "compose -f "*" config --services")
        printf 'postgres\nguacd\nguacamole\nnginx\n'
        ;;
    "compose -f "*" ps -q "*)
        echo "fakecontainerid"
        ;;
    "inspect --format "*)
        echo "starting"
        ;;
    "compose -f "*" ps")
        echo "fake ps output"
        ;;
esac
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    touch "$COMPOSE_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run wait_healthy 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out"* ]]
    [[ "$output" == *"docker compose logs"* ]]
}

@test "compose_up includes docker compose's own diagnostic in its failure message" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "compose" ]]; then
    echo "Error response from daemon: pull access denied for guacamole/guacamole" >&2
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    export ENV_FILE="$BATS_TEST_TMPDIR/.env"
    touch "$COMPOSE_FILE" "$ENV_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run compose_up
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull access denied"* ]]
    [[ "$output" == *"docker compose"* ]]
    [[ "$output" == *"logs"* ]]
}

@test "compose_up succeeds quietly when docker compose up succeeds" {
    stub_docker
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    export ENV_FILE="$BATS_TEST_TMPDIR/.env"
    touch "$COMPOSE_FILE" "$ENV_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run compose_up
    [ "$status" -eq 0 ]
    grep -q "compose --env-file ${ENV_FILE} -f ${COMPOSE_FILE} up -d" "$DOCKER_LOG"
}

@test "print_summary mentions the default guacadmin credentials and a change warning" {
    source bundle/install.sh
    run print_summary
    [[ "$output" == *"guacadmin"* ]]
    [[ "$output" == *"CHANGE"* ]]
}
