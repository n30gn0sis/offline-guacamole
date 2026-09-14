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
