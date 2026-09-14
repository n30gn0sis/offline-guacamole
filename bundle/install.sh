#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
ENV_TEMPLATE="${ENV_TEMPLATE:-$SCRIPT_DIR/env.template}"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/docker-compose.yml}"
IMAGES_DIR="${IMAGES_DIR:-$SCRIPT_DIR/images}"
CERT_DIR="${CERT_DIR:-$SCRIPT_DIR/nginx/certs}"
MIN_FREE_MB="${MIN_FREE_MB:-2048}"

log_info()  { printf '[install] INFO  %s\n' "$*" >&2; }
log_error() { printf '[install] ERROR %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

check_docker() {
    command -v docker >/dev/null 2>&1 \
        || die "Docker not found on PATH — install Docker Engine before running this installer."
    docker info >/dev/null 2>&1 \
        || die "Docker daemon is not reachable — is the docker service running, and are you in the docker group?"
}

check_compose() {
    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose v2 not found — install the docker-compose-plugin package."
}

check_ports_free() {
    local port
    for port in 80 443; do
        if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
            die "Port ${port} is already in use — stop the service using it before installing."
        fi
    done
}

check_disk_space() {
    local dir="$1" avail_mb
    avail_mb="$(df -Pm "$dir" | awk 'NR==2 {print $4}')"
    [[ "$avail_mb" -ge "$MIN_FREE_MB" ]] \
        || die "Only ${avail_mb} MB free under ${dir} — at least ${MIN_FREE_MB} MB free is required."
}

preflight_checks() {
    check_docker
    check_compose
    check_ports_free
    check_disk_space "$SCRIPT_DIR"
}

verify_manifest() {
    local root="$1" manifest="$1/manifest.sha256" err_file
    [[ -f "$manifest" ]] \
        || die "manifest.sha256 not found in ${root} — the bundle may be corrupt or incomplete."
    err_file="$(mktemp)"
    log_info "Verifying bundle integrity against manifest.sha256"
    if ! (cd "$root" && sha256sum -c manifest.sha256) >"$err_file" 2>&1; then
        log_error "Checksum verification failed — the following file(s) are missing or modified:"
        grep -v ': OK$' "$err_file" >&2 || true
        rm -f "$err_file"
        die "Bundle integrity check failed. Re-copy the bundle from a trusted source and retry."
    fi
    rm -f "$err_file"
}

configure_env() {
    if [[ -f "$ENV_FILE" ]]; then
        log_info ".env already exists at ${ENV_FILE} — leaving existing configuration untouched"
        return 0
    fi
    [[ -f "$ENV_TEMPLATE" ]] || die "env.template not found at ${ENV_TEMPLATE}"
    local pg_password
    pg_password="$(openssl rand -base64 24)"
    sed "s|__POSTGRES_PASSWORD__|${pg_password}|" "$ENV_TEMPLATE" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log_info "Generated ${ENV_FILE} with a random Postgres password (mode 600)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "install.sh: not yet fully implemented" >&2
    exit 1
fi
