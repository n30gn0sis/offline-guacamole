# tests/test_helper.bash
#
# stub_docker: replaces `docker` on PATH with a fake that logs every
# invocation (as a single space-joined line) to $DOCKER_LOG, and can be
# driven by an optional $DOCKER_STUB_SCRIPT (a bash script invoked with
# the same arguments, responsible for exit code / stdout / files).
stub_docker() {
    STUB_BIN_DIR="$(mktemp -d)"
    DOCKER_LOG="$STUB_BIN_DIR/docker.log"
    : > "$DOCKER_LOG"
    cat > "$STUB_BIN_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ -n "${DOCKER_STUB_SCRIPT:-}" ]]; then
    bash "$DOCKER_STUB_SCRIPT" "$@"
else
    exit 0
fi
STUB
    chmod +x "$STUB_BIN_DIR/docker"
    export PATH="$STUB_BIN_DIR:$PATH"
    export DOCKER_LOG
}

unstub_docker() {
    [[ -n "${STUB_BIN_DIR:-}" ]] && rm -rf "$STUB_BIN_DIR"
    unset STUB_BIN_DIR DOCKER_LOG
}

# stub_curl: same shape as stub_docker, for `curl`. Logs every invocation to
# $CURL_LOG and can be driven by an optional $CURL_STUB_SCRIPT (responsible
# for exit code / stdout). Shares STUB_BIN_DIR with stub_docker when that has
# already been called, so a single PATH entry covers both.
stub_curl() {
    if [[ -z "${STUB_BIN_DIR:-}" ]]; then
        STUB_BIN_DIR="$(mktemp -d)"
        export PATH="$STUB_BIN_DIR:$PATH"
    fi
    CURL_LOG="$STUB_BIN_DIR/curl.log"
    : > "$CURL_LOG"
    cat > "$STUB_BIN_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ -n "${CURL_STUB_SCRIPT:-}" ]]; then
    bash "$CURL_STUB_SCRIPT" "$@"
else
    exit 0
fi
STUB
    chmod +x "$STUB_BIN_DIR/curl"
    export CURL_LOG
}

unstub_curl() {
    [[ -n "${STUB_BIN_DIR:-}" ]] && rm -f "$STUB_BIN_DIR/curl"
    unset CURL_LOG CURL_STUB_SCRIPT
}
