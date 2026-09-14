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

# Emulate the one side effect of a real `docker save <ref> -o <file>` that
# save_images depends on: docker writes an image archive at <file> whose
# top-level manifest.json records RepoTags. $FAKE_REPOTAGS controls what goes
# in that array ("ref" = the ref it was asked to save, "null" = the null that
# a `repo:tag@digest` ref really produces).
write_docker_save_stub() {
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "save" ]]; then
    ref="$2"; prev=""; out=""
    for arg in "$@"; do
        [[ "$prev" == "-o" ]] && out="$arg"
        prev="$arg"
    done
    d="$(mktemp -d)"
    if [[ "${FAKE_REPOTAGS:-ref}" == "null" ]]; then
        printf '[{"Config":"config.json","RepoTags":null,"Layers":[]}]' > "$d/manifest.json"
    else
        printf '[{"Config":"config.json","RepoTags":["%s"],"Layers":[]}]' "$ref" > "$d/manifest.json"
    fi
    tar -C "$d" -cf "$out" manifest.json
    rm -rf "$d"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
}

@test "save_images saves each image by plain repo:tag to a lowercase-named tar" {
    # NOT by repo:tag@digest: `docker save` on a combined tag+digest ref emits
    # RepoTags:null, which makes the loaded image unaddressable on the target.
    stub_docker
    write_docker_save_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    out_dir="$BATS_TEST_TMPDIR/images"
    run save_images "$out_dir"
    [ "$status" -eq 0 ]
    grep -q "^save guacamole/guacamole:1.6.0 -o ${out_dir}/guacamole.tar$" "$DOCKER_LOG"
    grep -q "^save guacamole/guacd:1.6.0 -o ${out_dir}/guacd.tar$" "$DOCKER_LOG"
    grep -q "^save postgres:16-alpine -o ${out_dir}/postgres.tar$" "$DOCKER_LOG"
    grep -q "^save nginx:1.27-alpine -o ${out_dir}/nginx.tar$" "$DOCKER_LOG"
    # and no save was handed a digest-suffixed reference
    ! grep -q "^save .*@sha256:" "$DOCKER_LOG"
}

@test "save_images dies with an actionable message if a saved tar has no RepoTags" {
    stub_docker
    write_docker_save_stub
    export FAKE_REPOTAGS=null
    source build.sh
    load_versions "$VERSIONS_FILE"
    run save_images "$BATS_TEST_TMPDIR/images_null"
    [ "$status" -ne 0 ]
    [[ "$output" == *"guacamole.tar"* ]]
    [[ "$output" == *"RepoTags"* ]]
    [[ "$output" == *"unaddressable"* ]]
}

@test "save_images dies if docker save produces no readable archive" {
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    run save_images "$BATS_TEST_TMPDIR/images_empty"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest.json"* ]]
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
