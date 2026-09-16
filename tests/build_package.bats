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
    cat > "$BUNDLE_DIR/docker-compose.yml" <<'EOF'
services:
  postgres:
    image: __POSTGRES_IMAGE_REF__
  guacd:
    image: __GUACD_IMAGE_REF__
  guacamole:
    image: __GUACAMOLE_IMAGE_REF__
  nginx:
    image: __NGINX_IMAGE_REF__
EOF
    echo "install" > "$BUNDLE_DIR/install.sh"
    export DIST_DIR="$BATS_TEST_TMPDIR/dist"
}

teardown() {
    unstub_docker
}

# Emulate the side effects package_bundle depends on: `docker run` prints a
# schema on stdout, and `docker save <ref> -o <file>` writes a real image
# archive at <file> whose manifest.json records RepoTags for <ref>.
write_package_stub() {
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
elif [[ "$1" == "save" ]]; then
    ref="$2"; prev=""; out=""
    for arg in "$@"; do
        [[ "$prev" == "-o" ]] && out="$arg"
        prev="$arg"
    done
    d="$(mktemp -d)"
    printf '[{"Config":"config.json","RepoTags":["%s"],"Layers":[]}]' "$ref" > "$d/manifest.json"
    tar -C "$d" -cf "$out" manifest.json
    rm -rf "$d"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
}

@test "package_bundle produces a checksummed, self-consistent tarball" {
    stub_docker
    write_package_stub
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
    [ -f "$root/provenance.txt" ]
    [ -f "$root/manifest.sha256" ]
    (cd "$root" && sha256sum -c manifest.sha256)
}

@test "package_bundle substitutes every image placeholder in the packaged compose file" {
    stub_docker
    write_package_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    tarball="$(package_bundle "1.6.0")"
    extract_dir="$BATS_TEST_TMPDIR/extracted_sub"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    compose="$extract_dir/guacamole-offline-1.6.0/docker-compose.yml"

    ! grep -q '__[A-Z0-9_]*_IMAGE_REF__' "$compose"
    grep -q '^    image: guacamole/guacamole:1.6.0$' "$compose"
    grep -q '^    image: guacamole/guacd:1.6.0$' "$compose"
    grep -q '^    image: postgres:16-alpine$' "$compose"
    grep -q '^    image: nginx:1.27-alpine$' "$compose"
    # ...and never a digest-suffixed ref, which docker load cannot address
    ! grep -q '^    image: .*@sha256:' "$compose"
}

@test "package_bundle dies if a compose image placeholder is missing" {
    stub_docker
    write_package_stub
    sed -i 's/__NGINX_IMAGE_REF__/nginx:hardcoded/' "$BUNDLE_DIR/docker-compose.yml"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run package_bundle "1.6.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"__NGINX_IMAGE_REF__"* ]]
    [[ "$output" == *"single source of truth"* ]]
    [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]
}

@test "package_bundle dies if the compose file asks for an image that was not saved" {
    # The cross-check that ties the save side and the compose side together:
    # an image reference in the compose file that no saved tar provides must
    # fail the build rather than ship a bundle that pulls from a registry.
    stub_docker
    write_package_stub
    cat >> "$BUNDLE_DIR/docker-compose.yml" <<'EOF'
  extra:
    image: never/saved:9.9
EOF
    source build.sh
    load_versions "$VERSIONS_FILE"
    run package_bundle "1.6.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"asks for image"* ]]
    [[ "$output" == *"never/saved:9.9"* ]]
    [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]
}

@test "package_bundle writes a provenance record covered by the manifest" {
    stub_docker
    write_package_stub
    source build.sh
    load_versions "$VERSIONS_FILE"
    tarball="$(package_bundle "1.6.0")"
    extract_dir="$BATS_TEST_TMPDIR/extracted_prov"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    root="$extract_dir/guacamole-offline-1.6.0"
    prov="$root/provenance.txt"

    grep -q '^bundle_version=1\.6\.0$' "$prov"
    grep -qE '^built_at_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$prov"
    grep -qE '^built_from_git_rev=.+$' "$prov"
    grep -q '^guacamole_repo=guacamole/guacamole$' "$prov"
    grep -q '^guacamole_tag=1\.6\.0$' "$prov"
    grep -q '^guacamole_digest=sha256:1111' "$prov"
    grep -q '^nginx_digest=sha256:4444' "$prov"
    grep -q '^postgres_tar=images/postgres\.tar$' "$prov"
    # provenance.txt must be inside the manifest's coverage
    grep -q 'provenance\.txt' "$root/manifest.sha256"
}

@test "package_bundle strips a stale local .env and TLS certs from the source bundle/ dir before checksumming" {
    # Simulates a developer having run install.sh in place inside the repo
    # before building a release: install.sh's configure_env()/
    # generate_tls_cert() are deliberately idempotent and would silently
    # adopt these as "already configured" on the install side, so they must
    # never reach the shipped tree -- and must be stripped BEFORE
    # write_manifest runs, not after, or they'd be checksummed as
    # legitimate bundle content.
    stub_docker
    write_package_stub
    echo "POSTGRES_PASSWORD=leaked-builder-secret" > "$BUNDLE_DIR/.env"
    mkdir -p "$BUNDLE_DIR/nginx/certs"
    echo "leaked private key material" > "$BUNDLE_DIR/nginx/certs/privkey.pem"
    source build.sh
    load_versions "$VERSIONS_FILE"
    tarball="$(package_bundle "1.6.0")"

    extract_dir="$BATS_TEST_TMPDIR/extracted_secrets"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    root="$extract_dir/guacamole-offline-1.6.0"

    [ ! -e "$root/.env" ]
    [ ! -e "$root/nginx/certs/privkey.pem" ]
    [ ! -e "$root/nginx/certs" ]
    # The manifest must never have checksummed the leaked files in the
    # first place (they must be stripped before write_manifest runs).
    ! grep -q '\.env\|nginx/certs' "$root/manifest.sha256"
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

@test "stage_bundle_tree produces the staged tree alone: copied, stripped, schema generated, compose concrete, no tars" {
    stub_docker
    write_package_stub
    touch "$BUNDLE_DIR/.env"
    mkdir -p "$BUNDLE_DIR/nginx/certs" && touch "$BUNDLE_DIR/nginx/certs/privkey.pem"
    source build.sh
    load_versions "$VERSIONS_FILE"
    root="$BATS_TEST_TMPDIR/staged"
    run stage_bundle_tree "$root"
    [ "$status" -eq 0 ]
    [ -f "$root/install.sh" ]
    [ -s "$root/initdb/001-schema.sql" ]
    [ ! -e "$root/.env" ]
    [ ! -e "$root/nginx/certs" ]
    ! grep -q '__[A-Z]*_IMAGE_REF__' "$root/docker-compose.yml"
    grep -q 'image: guacamole/guacamole:1.6.0' "$root/docker-compose.yml"
    [ -d "$root/images" ]
    [ -z "$(ls -A "$root/images")" ]
    ! grep -q "^save" "$DOCKER_LOG"
}
