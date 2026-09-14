#!/usr/bin/env bats

load 'test_helper'

setup() {
    export CERT_DIR="$BATS_TEST_TMPDIR/certs"
}

@test "generate_tls_cert creates a self-signed cert and key when none exist" {
    source bundle/install.sh
    run generate_tls_cert
    [ "$status" -eq 0 ]
    [ -f "$CERT_DIR/fullchain.pem" ]
    [ -f "$CERT_DIR/privkey.pem" ]
    perms="$(stat -c '%a' "$CERT_DIR/privkey.pem")"
    [ "$perms" = "600" ]
    openssl x509 -in "$CERT_DIR/fullchain.pem" -noout
}

@test "generate_tls_cert leaves an existing cert/key pair untouched" {
    mkdir -p "$CERT_DIR"
    echo "existing-cert" > "$CERT_DIR/fullchain.pem"
    echo "existing-key" > "$CERT_DIR/privkey.pem"
    source bundle/install.sh
    generate_tls_cert
    grep -q "existing-cert" "$CERT_DIR/fullchain.pem"
    grep -q "existing-key" "$CERT_DIR/privkey.pem"
}

@test "generate_tls_cert dies if only cert exists (partial pair)" {
    mkdir -p "$CERT_DIR"
    echo "existing-cert" > "$CERT_DIR/fullchain.pem"
    source bundle/install.sh
    run generate_tls_cert
    [ "$status" -ne 0 ]
    grep -q "existing-cert" "$CERT_DIR/fullchain.pem"
    [ ! -f "$CERT_DIR/privkey.pem" ]
}

@test "generate_tls_cert dies with openssl's own diagnostic when openssl fails" {
    # Previously openssl's stderr was sent to /dev/null with no || die, so a
    # failure aborted the installer under `set -e` printing nothing at all.
    stub_openssl_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub_openssl_dir"
    cat > "$stub_openssl_dir/openssl" <<'EOF'
#!/usr/bin/env bash
echo "on this stub, rsa:2048 key generation is unavailable" >&2
exit 1
EOF
    chmod +x "$stub_openssl_dir/openssl"
    source bundle/install.sh
    local original_path="$PATH"
    export PATH="$stub_openssl_dir:$PATH"
    run generate_tls_cert
    export PATH="$original_path"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to generate a self-signed TLS certificate"* ]]
    [[ "$output" == *"rsa:2048 key generation is unavailable"* ]]
}

@test "generate_tls_cert dies if only key exists (partial pair)" {
    mkdir -p "$CERT_DIR"
    echo "existing-key" > "$CERT_DIR/privkey.pem"
    source bundle/install.sh
    run generate_tls_cert
    [ "$status" -ne 0 ]
    grep -q "existing-key" "$CERT_DIR/privkey.pem"
    [ ! -f "$CERT_DIR/fullchain.pem" ]
}
