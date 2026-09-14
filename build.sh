#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$SCRIPT_DIR/versions.env}"
BUNDLE_DIR="${BUNDLE_DIR:-$SCRIPT_DIR/bundle}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"

COMPONENT_NAMES=(GUACAMOLE GUACD POSTGRES NGINX)

log_info()  { printf '[build] INFO  %s\n' "$*" >&2; }
log_error() { printf '[build] ERROR %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

all_component_names() {
    printf '%s\n' "${COMPONENT_NAMES[@]}"
}

load_versions() {
    local file="$1" name repo_var tag_var digest_var
    [[ -f "$file" ]] || die "versions file not found: $file"
    # shellcheck disable=SC1090
    source "$file"
    for name in "${COMPONENT_NAMES[@]}"; do
        repo_var="${name}_IMAGE"
        tag_var="${name}_TAG"
        digest_var="${name}_DIGEST"
        [[ -n "${!repo_var:-}" ]] || die "${repo_var} is not set in $file"
        [[ -n "${!tag_var:-}" ]] || die "${tag_var} is not set in $file"
        [[ "${!digest_var:-}" =~ ^sha256:[0-9a-f]{64}$ ]] \
            || die "${digest_var} is missing or not a valid sha256 digest in $file"
    done
}

image_ref() {
    local name="$1" repo_var tag_var digest_var
    repo_var="${name}_IMAGE"
    tag_var="${name}_TAG"
    digest_var="${name}_DIGEST"
    printf '%s:%s@%s' "${!repo_var}" "${!tag_var}" "${!digest_var}"
}

pull_images() {
    local name ref
    for name in $(all_component_names); do
        ref="$(image_ref "$name")"
        log_info "Pulling ${ref}"
        docker pull "${ref}" || die "Failed to pull ${ref}"
    done
}

generate_schema() {
    local out_dir="$1" guac_ref
    guac_ref="$(image_ref GUACAMOLE)"
    mkdir -p "$out_dir"
    log_info "Generating Postgres schema from ${guac_ref}"
    # NOTE: /opt/guacamole/bin/initdb.sh is the path used by the official
    # guacamole/guacamole image as of 1.6.0. If a future version moves it,
    # `docker run --rm <ref> find / -name initdb.sh` will locate it —
    # update this path accordingly.
    docker run --rm "${guac_ref}" /opt/guacamole/bin/initdb.sh --postgresql \
        > "$out_dir/001-schema.sql" \
        || die "Failed to run initdb.sh in ${guac_ref}"
    [[ -s "$out_dir/001-schema.sql" ]] \
        || die "schema generation produced an empty file — check 'docker run --rm ${guac_ref} /opt/guacamole/bin/initdb.sh --postgresql' manually"
}

save_images() {
    local out_dir="$1" name ref safe_name
    mkdir -p "$out_dir"
    for name in $(all_component_names); do
        ref="$(image_ref "$name")"
        safe_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        log_info "Saving ${ref} -> ${out_dir}/${safe_name}.tar"
        docker save "${ref}" -o "${out_dir}/${safe_name}.tar" || die "Failed to save ${ref} to ${out_dir}/${safe_name}.tar"
    done
}

write_manifest() {
    local root_dir="$1"
    (
        cd "$root_dir" || exit 1
        find . -type f ! -name 'manifest.sha256' -print0 \
            | sort -z \
            | xargs -0 sha256sum
    ) > "$root_dir/manifest.sha256" || die "Failed to write manifest.sha256 in ${root_dir}"
}

package_bundle() {
    local version="$1" work_dir root date_stamp tarball_name
    date_stamp="$(date -u +%Y%m%d)"
    tarball_name="guacamole-offline-${version}-${date_stamp}.tar.gz"

    # The work_dir/root assembly runs in a subshell so its cleanup trap is an
    # EXIT trap, not a RETURN trap: under `set -T` (functrace, e.g. bats'
    # `set -eET` test runner) a RETURN trap set here would be inherited by
    # every nested function call this makes (generate_schema, image_ref, ...)
    # and fire the moment any of THEM returns, deleting work_dir mid-build.
    # EXIT firing is tied to actual (sub)shell termination, not per-function
    # return, so it isn't subject to that inheritance and fires exactly once,
    # when this subshell finishes.
    (
        work_dir="$(mktemp -d "${TMPDIR:-/tmp}/guac-build.XXXXXX")"
        trap 'rm -rf "$work_dir"' EXIT

        root="$work_dir/guacamole-offline-${version}"
        mkdir -p "$root/images" "$root/initdb"
        cp -a "$BUNDLE_DIR"/. "$root/"

        generate_schema "$root/initdb"
        save_images "$root/images"
        write_manifest "$root"

        mkdir -p "$DIST_DIR"
        tar -C "$work_dir" -czf "$DIST_DIR/${tarball_name}.partial" "guacamole-offline-${version}"
    ) || die "Failed to assemble bundle for version ${version}"
    # The explicit `|| die` above (rather than relying on `set -e` to abort
    # package_bundle when the subshell fails) matters because callers that
    # invoke this via bats' `run` helper have errexit disabled for the
    # duration of the call (`run` does `set +eET`) — without it, a failure
    # inside the subshell would be silently ignored and execution would fall
    # through to `mv` a `.partial` file that was never written.
    mv "$DIST_DIR/${tarball_name}.partial" "$DIST_DIR/${tarball_name}"
    log_info "Bundle written to $DIST_DIR/${tarball_name}"
    printf '%s\n' "$DIST_DIR/${tarball_name}"
}

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--selftest]

Builds the offline Guacamole bundle described by versions.env into dist/.
--selftest also unpacks the result and runs install.sh against it locally.
EOF
}

run_selftest() {
    # The whole selftest body runs in a subshell so cleanup is tied to
    # actual (sub)shell termination via an EXIT trap, not a function RETURN
    # trap. A RETURN trap only fires when a function returns normally (via
    # `return`, or falling off the end) -- NOT when `exit` is called, be it
    # directly, via `die`, or via `set -e`/errexit, while that function is
    # still on the call stack (verified empirically: a RETURN trap set in a
    # function that instead exits via `die`/errexit never fires at all).
    # Nearly every failure path below goes through `die` or an unguarded
    # command under errexit, so a bare RETURN trap here would only ever run
    # on success -- leaving the extracted tarball, and possibly a running
    # compose stack bound to ports 80/443, behind on every failure. This is
    # a different problem from Task 6's RETURN-trap issue (which was
    # specific to bats' functrace option); this one is plain bash trap
    # semantics and applies with no bats involved.
    #
    # Unlike `package_bundle`, this subshell is a bare statement (not the
    # left side of `||`), so `set -e` still propagates into it exactly as
    # it would without the subshell -- the unguarded `tar`/`install.sh`
    # calls below still abort immediately on failure, same as they would
    # without this wrapping.
    (
        # Note: this local is named `bundle_root`, not `root` as in the
        # brief, purely to avoid a shellcheck SC2030/SC2031 false positive
        # -- shellcheck otherwise cross-links it with package_bundle's own
        # unrelated local `root` (different function, different subshell)
        # purely because they share a name. No behavior change.
        local tarball="$1" extract_dir bundle_root

        extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/guac-selftest.XXXXXX")"
        trap 'rm -rf "$extract_dir"; ( cd "$bundle_root" 2>/dev/null && docker compose -f docker-compose.yml down -v ) 2>/dev/null || true' EXIT

        log_info "Selftest: extracting $tarball"
        tar -xzf "$tarball" -C "$extract_dir"
        bundle_root="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

        log_info "Selftest: running install.sh against the extracted bundle"
        ( cd "$bundle_root" && ./install.sh )

        log_info "Selftest: checking the login page over HTTPS"
        curl -fsSk "https://127.0.0.1/guacamole/" >/dev/null \
            || die "Selftest failed: login page did not respond over HTTPS"

        log_info "Selftest: logging in as guacadmin via the API to confirm the schema initialized"
        local token
        token="$(curl -fsSk -X POST "https://127.0.0.1/guacamole/api/tokens" \
            -d "username=guacadmin&password=guacadmin" \
            | grep -o '"authToken":"[^"]*"' | cut -d'"' -f4)"
        [[ -n "$token" ]] || die "Selftest failed: could not obtain an authToken for guacadmin — schema may not have initialized"

        log_info "Selftest passed: $tarball is a valid release"
    )
}

main() {
    local selftest=0 version
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --selftest) selftest=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1 (see --help)" ;;
        esac
        shift
    done

    load_versions "$VERSIONS_FILE"
    version="$GUACAMOLE_TAG"
    pull_images
    local tarball
    tarball="$(package_bundle "$version")"

    if [[ "$selftest" -eq 1 ]]; then
        run_selftest "$tarball"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
