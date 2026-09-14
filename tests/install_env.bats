#!/usr/bin/env bats

load 'test_helper'

setup() {
    export ENV_TEMPLATE="$BATS_TEST_TMPDIR/env.template"
    export ENV_FILE="$BATS_TEST_TMPDIR/.env"
    cat > "$ENV_TEMPLATE" <<'EOF'
POSTGRES_DB=guacamole_db
POSTGRES_USER=guacamole
POSTGRES_PASSWORD=__POSTGRES_PASSWORD__
EOF
}

@test "configure_env generates a random password and writes a 600 .env on first run" {
    source bundle/install.sh
    run configure_env
    [ "$status" -eq 0 ]
    [ -f "$ENV_FILE" ]
    perms="$(stat -c '%a' "$ENV_FILE")"
    [ "$perms" = "600" ]
    ! grep -q '__POSTGRES_PASSWORD__' "$ENV_FILE"
    grep -q '^POSTGRES_PASSWORD=' "$ENV_FILE"
}

@test "configure_env leaves an existing .env untouched on re-run" {
    echo "POSTGRES_PASSWORD=already-set" > "$ENV_FILE"
    source bundle/install.sh
    configure_env
    grep -q '^POSTGRES_PASSWORD=already-set$' "$ENV_FILE"
}

@test "configure_env dies if env.template is missing" {
    rm "$ENV_TEMPLATE"
    source bundle/install.sh
    run configure_env
    [ "$status" -ne 0 ]
    [[ "$output" == *"env.template"* ]]
}
