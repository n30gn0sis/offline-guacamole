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

generate_tls_cert() {
    local cert="$CERT_DIR/fullchain.pem" key="$CERT_DIR/privkey.pem"
    if [[ -f "$cert" && -f "$key" ]]; then
        log_info "TLS certificate already present at ${CERT_DIR} — leaving it in place"
        return 0
    fi
    if [[ -f "$cert" || -f "$key" ]]; then
        die "Found only one of fullchain.pem/privkey.pem in ${CERT_DIR} — remove the stray file or supply the matching one before re-running install.sh"
    fi
    mkdir -p "$CERT_DIR"
    log_info "Generating a self-signed TLS certificate (365 days) at ${CERT_DIR}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$key" -out "$cert" -days 365 \
        -subj "/CN=guacamole.local" \
        >/dev/null 2>&1
    chmod 600 "$key"
}

load_images() {
    local tar_file found=0
    for tar_file in "$IMAGES_DIR"/*.tar; do
        [[ -e "$tar_file" ]] || continue
        found=1
        log_info "Loading $(basename "$tar_file")"
        docker load -i "$tar_file"
    done
    [[ "$found" -eq 1 ]] || die "No image tars found in ${IMAGES_DIR} — the bundle may be corrupt or incomplete."
}

compose_up() {
    ( cd "$SCRIPT_DIR" && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d ) \
        || die "Failed to bring up the compose stack"
}

wait_healthy() {
    local timeout="${1:-180}" elapsed=0 services svc cid status unhealthy

    services="$(cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" config --services)" \
        || die "Failed to determine compose services"
    log_info "Waiting up to ${timeout}s for all services to report healthy"

    while (( elapsed < timeout )); do
        unhealthy=0
        for svc in $services; do
            cid="$(cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" ps -q "$svc")"
            if [[ -z "$cid" ]]; then
                unhealthy=1
                continue
            fi
            status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo "unknown")"
            [[ "$status" == "healthy" ]] || unhealthy=1
        done
        if [[ "$unhealthy" -eq 0 ]]; then
            log_info "All services healthy"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done

    log_error "Timed out waiting for services to become healthy. Current status:"
    ( cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" ps ) >&2 || true
    for svc in $services; do
        log_error "  -> run: (cd ${SCRIPT_DIR} && docker compose logs ${svc})"
    done
    die "Stack did not become healthy within ${timeout}s"
}

print_summary() {
    cat <<'EOF'

Guacamole is up.

  URL:    https://<this-host>/guacamole/
  Login:  guacadmin / guacadmin

  *** CHANGE THE DEFAULT guacadmin PASSWORD NOW ***
  Settings -> Users -> guacadmin -> change password, immediately after first login.

EOF
}

main() {
    preflight_checks
    verify_manifest "$SCRIPT_DIR"
    load_images
    configure_env
    generate_tls_cert
    compose_up
    wait_healthy 180
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
