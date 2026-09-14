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

@test "pull_images pulls all four images by digest reference" {
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -eq 0 ]
    grep -q "pull guacamole/guacamole:1.6.0@sha256:1111" "$DOCKER_LOG"
    grep -q "pull guacamole/guacd:1.6.0@sha256:2222" "$DOCKER_LOG"
    grep -q "pull postgres:16-alpine@sha256:3333" "$DOCKER_LOG"
    grep -q "pull nginx:1.27-alpine@sha256:4444" "$DOCKER_LOG"
}

@test "pull_images re-tags each digest-pinned image under its plain repo:tag" {
    # `docker pull repo:tag@digest` leaves the image with NO local tag, so
    # without this step docker save later emits RepoTags:null and the loaded
    # image is unaddressable on the target.
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -eq 0 ]
    grep -q "^tag guacamole/guacamole:1.6.0@sha256:1111.* guacamole/guacamole:1.6.0$" "$DOCKER_LOG"
    grep -q "^tag guacamole/guacd:1.6.0@sha256:2222.* guacamole/guacd:1.6.0$" "$DOCKER_LOG"
    grep -q "^tag postgres:16-alpine@sha256:3333.* postgres:16-alpine$" "$DOCKER_LOG"
    grep -q "^tag nginx:1.27-alpine@sha256:4444.* nginx:1.27-alpine$" "$DOCKER_LOG"
}

@test "pull_images dies with an actionable message if the re-tag fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "tag" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to tag"* ]]
    [[ "$output" == *"addressable by name on the target"* ]]
}

@test "image_repo_tag renders the plain repo:tag with no digest suffix" {
    source build.sh
    load_versions "$VERSIONS_FILE"
    [ "$(image_repo_tag GUACAMOLE)" = "guacamole/guacamole:1.6.0" ]
    [ "$(image_repo_tag POSTGRES)" = "postgres:16-alpine" ]
}

@test "pull_images fails loudly if a pull fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1 $2" == "pull guacamole/guacd:1.6.0@sha256:2222222222222222222222222222222222222222222222222222222222222222" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -ne 0 ]
}
