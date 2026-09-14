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
