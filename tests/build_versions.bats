#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VALID_VERSIONS="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VALID_VERSIONS" <<'EOF'
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

@test "load_versions accepts a fully-populated, valid versions.env" {
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -eq 0 ]
}

@test "load_versions rejects a missing digest" {
    sed -i 's/^GUACD_DIGEST=.*/GUACD_DIGEST=/' "$VALID_VERSIONS"
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GUACD_DIGEST"* ]]
}

@test "load_versions rejects a malformed (non-sha256) digest" {
    sed -i 's/^NGINX_DIGEST=.*/NGINX_DIGEST=notadigest/' "$VALID_VERSIONS"
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NGINX_DIGEST"* ]]
}

@test "image_ref renders repo:tag@digest" {
    source build.sh
    load_versions "$VALID_VERSIONS"
    result="$(image_ref GUACAMOLE)"
    [ "$result" = "guacamole/guacamole:1.6.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
}
