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
    export BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE_DIR/nginx"
    echo "compose" > "$BUNDLE_DIR/docker-compose.yml"
    echo "install" > "$BUNDLE_DIR/install.sh"
    export DIST_DIR="$BATS_TEST_TMPDIR/dist"
}

teardown() {
    unstub_docker
}

@test "package_bundle produces a checksummed, self-consistent tarball" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
elif [[ "$1" == "save" ]]; then
    # Real `docker save ... -o FILE` has docker itself write FILE; this stub
    # doesn't run real docker, so emulate that one side effect: touch
    # whatever path follows a trailing `-o` so package_bundle sees a real
    # (if empty) file at the path save_images told docker to write to.
    prev=""
    for arg in "$@"; do
        if [[ "$prev" == "-o" ]]; then
            touch "$arg"
        fi
        prev="$arg"
    done
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    tarball="$(package_bundle "1.6.0")"
    [ -f "$tarball" ]
    [[ "$tarball" == "$DIST_DIR"/guacamole-offline-1.6.0-*.tar.gz ]]

    extract_dir="$BATS_TEST_TMPDIR/extracted"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    root="$extract_dir/guacamole-offline-1.6.0"
    [ -f "$root/docker-compose.yml" ]
    [ -f "$root/install.sh" ]
    [ -f "$root/initdb/001-schema.sql" ]
    [ -f "$root/images/guacamole.tar" ]
    [ -f "$root/manifest.sha256" ]
    (cd "$root" && sha256sum -c manifest.sha256)
}

@test "package_bundle leaves no partial tarball in dist/ if schema generation fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run package_bundle "1.6.0"
    [ "$status" -ne 0 ]
    [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]
}
