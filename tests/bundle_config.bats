#!/usr/bin/env bats

# The repo copy of bundle/docker-compose.yml carries __*_IMAGE_REF__
# placeholders that build.sh substitutes at package time. `docker compose
# config` validates YAML structure, schema keys and variable interpolation —
# it does not validate image-reference grammar — so it still meaningfully
# checks the raw file (verified: a placeholder image value is accepted). The
# substituted-copy test below covers the half that placeholders do hide.
substituted_compose() {
    local out="$BATS_TEST_TMPDIR/docker-compose.substituted.yml"
    sed -e 's|__GUACAMOLE_IMAGE_REF__|guacamole/guacamole:1.6.0|' \
        -e 's|__GUACD_IMAGE_REF__|guacamole/guacd:1.6.0|' \
        -e 's|__POSTGRES_IMAGE_REF__|postgres:16-alpine|' \
        -e 's|__NGINX_IMAGE_REF__|nginx:1.27-alpine|' \
        bundle/docker-compose.yml > "$out"
    printf '%s' "$out"
}

@test "docker-compose.yml is syntactically valid" {
    run docker compose -f bundle/docker-compose.yml --env-file bundle/env.template config -q
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml is still valid once its image placeholders are substituted" {
    compose="$(substituted_compose)"
    run docker compose -f "$compose" --env-file bundle/env.template config -q
    [ "$status" -eq 0 ]
    run docker compose -f "$compose" --env-file bundle/env.template config
    [ "$status" -eq 0 ]
    [[ "$output" == *"image: guacamole/guacamole:1.6.0"* ]]
    [[ "$output" == *"image: nginx:1.27-alpine"* ]]
}

@test "docker-compose.yml defines exactly the four expected services" {
    services="$(docker compose -f bundle/docker-compose.yml --env-file bundle/env.template config --services | sort)"
    expected="$(printf 'guacamole\nguacd\nnginx\npostgres')"
    [ "$services" = "$expected" ]
}

@test "docker-compose.yml carries one image placeholder per component and no hardcoded refs" {
    # versions.env is the single source of truth: build.sh substitutes these.
    for marker in __GUACAMOLE_IMAGE_REF__ __GUACD_IMAGE_REF__ __POSTGRES_IMAGE_REF__ __NGINX_IMAGE_REF__; do
        [ "$(grep -c "image: ${marker}\$" bundle/docker-compose.yml)" -eq 1 ]
    done
    # every `image:` line is a placeholder — none hardcoded
    [ "$(grep -cE '^[[:space:]]+image:' bundle/docker-compose.yml)" -eq 4 ]
    [ "$(grep -cE '^[[:space:]]+image: __[A-Z0-9_]+_IMAGE_REF__$' bundle/docker-compose.yml)" -eq 4 ]
}

@test "every service sets pull_policy: never so the stack can never reach a registry" {
    [ "$(grep -cE '^[[:space:]]+pull_policy: never$' bundle/docker-compose.yml)" -eq 4 ]
    compose="$(substituted_compose)"
    run docker compose -f "$compose" --env-file bundle/env.template config
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c 'pull_policy: never')" -eq 4 ]
}

@test "nginx.conf passes nginx -t against a dummy cert" {
    cert_dir="$BATS_TEST_TMPDIR/certs"
    mkdir -p "$cert_dir"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$cert_dir/privkey.pem" -out "$cert_dir/fullchain.pem" \
        -days 1 -subj "/CN=test" >/dev/null 2>&1
    run docker run --rm \
        -v "$(pwd)/bundle/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$cert_dir:/etc/nginx/certs:ro" \
        nginx:1.27-alpine nginx -t
    [ "$status" -eq 0 ]
}

@test "env.template contains the password marker configure_env() replaces" {
    grep -q '__POSTGRES_PASSWORD__' bundle/env.template
}
