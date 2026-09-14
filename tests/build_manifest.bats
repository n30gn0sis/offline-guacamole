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

@test "save_images saves each image to a lowercase-named tar" {
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    out_dir="$BATS_TEST_TMPDIR/images"
    run save_images "$out_dir"
    [ "$status" -eq 0 ]
    grep -q "save guacamole/guacamole:1.6.0@sha256:1111.*-o ${out_dir}/guacamole.tar" "$DOCKER_LOG"
    grep -q "save guacamole/guacd:1.6.0@sha256:2222.*-o ${out_dir}/guacd.tar" "$DOCKER_LOG"
    grep -q "save postgres:16-alpine@sha256:3333.*-o ${out_dir}/postgres.tar" "$DOCKER_LOG"
    grep -q "save nginx:1.27-alpine@sha256:4444.*-o ${out_dir}/nginx.tar" "$DOCKER_LOG"
}

@test "write_manifest writes a checksum for every file except itself" {
    root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/images" "$root/initdb"
    echo "a" > "$root/images/guacamole.tar"
    echo "b" > "$root/initdb/001-schema.sql"
    source build.sh
    write_manifest "$root"
    [ -f "$root/manifest.sha256" ]
    run sha256sum -c "$root/manifest.sha256"
    cd "$root" && run sha256sum -c manifest.sha256
    [ "$status" -eq 0 ]
    ! grep -q "manifest.sha256" "$root/manifest.sha256"
}
