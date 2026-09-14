#!/usr/bin/env bats

@test "docker-compose.yml is syntactically valid" {
    run docker compose -f bundle/docker-compose.yml --env-file bundle/env.template config -q
    [ "$status" -eq 0 ]
}

@test "docker-compose.yml defines exactly the four expected services" {
    services="$(docker compose -f bundle/docker-compose.yml --env-file bundle/env.template config --services | sort)"
    expected="$(printf 'guacamole\nguacd\nnginx\npostgres')"
    [ "$services" = "$expected" ]
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
