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

# The plain `repo:tag` form of a component, with no digest suffix. This is
# the name the shipped docker-compose.yml asks for and the name each image
# tar is saved under — see pull_images()/save_images() below for why the
# digest-pinned ref cannot be used for either.
image_repo_tag() {
    local name="$1" repo_var tag_var
    repo_var="${name}_IMAGE"
    tag_var="${name}_TAG"
    printf '%s:%s' "${!repo_var}" "${!tag_var}"
}

pull_images() {
    local name ref plain
    for name in $(all_component_names); do
        ref="$(image_ref "$name")"
        plain="$(image_repo_tag "$name")"
        log_info "Pulling ${ref}"
        # Pulling the combined repo:tag@digest ref IS the digest pin: docker
        # normalizes it to a pure repo@digest reference (the tag is ignored
        # for resolution) and either fetches exactly that digest's content or
        # fails outright if that digest does not exist in that repo. Verified
        # empirically against a local registry: a wrong digest fails with
        # "... not found" and a non-zero exit, so no separate resolved-digest
        # comparison is needed — this `|| die` is the digest-mismatch gate.
        docker pull "${ref}" || die "Failed to pull ${ref} — the pinned digest may no longer exist in that repository, or the registry is unreachable. Re-check ${name}_DIGEST in ${VERSIONS_FILE}."
        # ...but precisely because the tag is ignored, the pulled image ends
        # up with NO local repo:tag at all (docker images shows it as
        # "repo:<none>"). Tag it explicitly so the image is addressable by
        # the name docker-compose.yml uses. Without this, `docker save` later
        # emits a tar with RepoTags:null, and `docker load` on the air-gapped
        # target produces a dangling, unaddressable image that compose cannot
        # find — the bundle would silently not work offline.
        log_info "Tagging ${ref} as ${plain}"
        docker tag "${ref}" "${plain}" \
            || die "Failed to tag ${ref} as ${plain} — the bundled image would not be addressable by name on the target."
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

# Extract the RepoTags entries recorded in a `docker save` tar's manifest.json.
# Both the legacy and the containerd/OCI archive layouts carry a top-level
# manifest.json with a RepoTags array, so this works on either. Kept to
# tar+grep rather than jq deliberately: nothing else in this repo depends on
# jq, and build.sh should not grow a new hard dependency for one assertion.
assert_tar_repotags() {
    local tar_file="$1" expected="$2" manifest
    manifest="$(tar -xOf "$tar_file" manifest.json 2>/dev/null)" \
        || die "Could not read manifest.json out of ${tar_file} — 'docker save' did not produce a well-formed image archive."
    printf '%s' "$manifest" | grep -qF "\"${expected}\"" \
        || die "${tar_file} does not record RepoTags[\"${expected}\"] — the image would load on the target as an unaddressable, dangling image and docker compose would not find it. This happens when 'docker save' is handed a repo:tag@digest reference instead of a plain repo:tag."
}

save_images() {
    local out_dir="$1" name plain safe_name tar_file
    mkdir -p "$out_dir"
    for name in $(all_component_names); do
        # Save by plain repo:tag, NOT by the digest-pinned ref: `docker save`
        # on a repo:tag@digest reference emits RepoTags:null (and no
        # io.containerd.image.name annotation), which makes the loaded image
        # unaddressable on the target. pull_images() has already tagged the
        # exact digest-pinned content as this repo:tag, so the content saved
        # here is still precisely what versions.env pinned.
        plain="$(image_repo_tag "$name")"
        safe_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        tar_file="${out_dir}/${safe_name}.tar"
        log_info "Saving ${plain} -> ${tar_file}"
        docker save "${plain}" -o "${tar_file}" || die "Failed to save ${plain} to ${tar_file}"
        assert_tar_repotags "$tar_file" "$plain"
    done
}

# Every `image:` value declared in a compose file, one per line. The bundled
# compose file never quotes these, so awk on field 2 is sufficient; the same
# one-liner is used on the install side (bundle/install.sh) so both halves
# agree on what "the images this bundle needs" means.
compose_image_refs() {
    local compose_file="$1"
    awk '$1 == "image:" { print $2 }' "$compose_file"
}

# Replace the __<COMPONENT>_IMAGE_REF__ markers in the ASSEMBLED compose file
# with the concrete repo:tag resolved from versions.env. Done at build time
# (not install time, as with env.template's __POSTGRES_PASSWORD__) because
# the versions are known when build.sh runs and the shipped bundle must be
# fully concrete and self-consistent.
substitute_compose_images() {
    local compose_file="$1" name plain placeholder leftover
    [[ -f "$compose_file" ]] \
        || die "docker-compose.yml not found at ${compose_file} — the bundle assembly is incomplete."
    for name in $(all_component_names); do
        plain="$(image_repo_tag "$name")"
        placeholder="__${name}_IMAGE_REF__"
        grep -qF "$placeholder" "$compose_file" \
            || die "${placeholder} not found in ${compose_file} — bundle/docker-compose.yml must carry one '${placeholder}' image: line so versions.env stays the single source of truth for image references."
        # '|' as the sed delimiter: image references contain '/' and ':' but
        # never '|'. Same convention as install.sh's env.template substitution.
        sed -i "s|${placeholder}|${plain}|g" "$compose_file" \
            || die "Failed to substitute ${placeholder} in ${compose_file}"
    done
    leftover="$(grep -o '__[A-Z0-9_]*_IMAGE_REF__' "$compose_file" | sort -u | tr '\n' ' ')" || true
    [[ -z "$leftover" ]] \
        || die "Unsubstituted image placeholder(s) left in ${compose_file}: ${leftover}— every placeholder must correspond to a component in COMPONENT_NAMES."
}

# Tie the two halves together: every image the assembled compose file asks
# for must be recorded as a RepoTags entry in one of the tars just saved
# into images/. This is the build-time guard against both the "saved under
# the wrong name" bug and the "compose asks for something we never saved"
# bug, in one check.
assert_compose_images_saved() {
    local compose_file="$1" images_dir="$2" ref tar_file found
    while read -r ref; do
        [[ -n "$ref" ]] || continue
        found=0
        for tar_file in "$images_dir"/*.tar; do
            [[ -e "$tar_file" ]] || continue
            if tar -xOf "$tar_file" manifest.json 2>/dev/null | grep -qF "\"${ref}\""; then
                found=1
                break
            fi
        done
        [[ "$found" -eq 1 ]] \
            || die "${compose_file} asks for image '${ref}', but no tar in ${images_dir} was saved under that name — the bundle would try to pull it from a registry on the target. Check versions.env and the __*_IMAGE_REF__ placeholders in bundle/docker-compose.yml."
    done < <(compose_image_refs "$compose_file")
}

# A record of what this bundle actually contains, so an operator on the
# disconnected side can answer "what did I just install?" without a registry.
write_provenance() {
    local root_dir="$1" version="$2" name repo_var tag_var digest_var git_rev lower
    git_rev="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)" || git_rev=""
    [[ -n "$git_rev" ]] || git_rev="unknown (build.sh was not run from a git checkout)"
    {
        printf '# Apache Guacamole offline bundle — provenance record\n'
        printf '# Generated by build.sh. Covered by manifest.sha256.\n'
        printf '\n'
        printf 'bundle_version=%s\n' "$version"
        printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'built_from_git_rev=%s\n' "$git_rev"
        printf 'built_from_versions_file=%s\n' "$(basename "$VERSIONS_FILE")"
        for name in $(all_component_names); do
            repo_var="${name}_IMAGE"
            tag_var="${name}_TAG"
            digest_var="${name}_DIGEST"
            lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
            printf '\n'
            printf '%s_repo=%s\n' "$lower" "${!repo_var}"
            printf '%s_tag=%s\n' "$lower" "${!tag_var}"
            printf '%s_digest=%s\n' "$lower" "${!digest_var}"
            printf '%s_tar=images/%s.tar\n' "$lower" "$lower"
        done
    } > "$root_dir/provenance.txt" \
        || die "Failed to write provenance.txt in ${root_dir}"
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
        # Strip any builder-local secrets that install.sh may have written
        # into bundle/ when run in place (e.g. by a developer testing
        # locally): a live .env with a real Postgres password, and a
        # generated TLS private key/cert under nginx/certs/. This must run
        # before write_provenance/write_manifest below -- install.sh's
        # configure_env()/generate_tls_cert() are deliberately idempotent
        # and treat an existing .env or cert/key pair as "already
        # configured", so if these ever leaked into a shipped bundle every
        # site installing from it would silently adopt the same DB
        # password and the same TLS private key. Neither path is
        # guaranteed to exist (a fresh checkout that never had install.sh
        # run in it has neither) so this must not be treated as failure.
        rm -rf "$root/.env" "$root/nginx/certs"

        generate_schema "$root/initdb"
        save_images "$root/images"
        substitute_compose_images "$root/docker-compose.yml"
        assert_compose_images_saved "$root/docker-compose.yml" "$root/images"
        write_provenance "$root" "$version"
        # write_manifest runs last so it covers provenance.txt and the
        # substituted compose file — i.e. everything the target will verify.
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

# Set by main() for the duration of the selftest only; consumed by
# mark_unverified_on_exit.
SELFTEST_TARBALL=""

# EXIT-trap handler installed around the run_selftest call. package_bundle
# moves the finished tarball into dist/ under its real release name BEFORE
# the selftest runs against it, so a failed selftest would otherwise leave a
# known-bad tarball in dist/ looking exactly like a passing release.
#
# This is deliberately an EXIT trap in the TOP-LEVEL shell rather than a
# conditional around the call. Wrapping run_selftest in `if ! ...`, `|| ...`
# or `&& ...` would put it in a condition context, and bash propagates that
# errexit suppression *into the subshell that forms run_selftest's body*
# (verified empirically) — every unguarded command in the selftest would
# stop aborting it, silently destroying the error-propagation behavior that
# function was carefully built around. A bare call plus this trap keeps
# run_selftest's own semantics and its own EXIT trap completely untouched:
# that trap fires inside its subshell, this one fires when the top-level
# shell exits, and they never interact.
mark_unverified_on_exit() {
    local rc=$?
    if (( rc != 0 )) && [[ -n "$SELFTEST_TARBALL" && -f "$SELFTEST_TARBALL" ]]; then
        if mv "$SELFTEST_TARBALL" "${SELFTEST_TARBALL}.FAILED"; then
            log_error "Selftest did not pass — renamed the tarball to ${SELFTEST_TARBALL}.FAILED so it cannot be mistaken for a valid release. Do not ship it."
        else
            log_error "Selftest did not pass AND ${SELFTEST_TARBALL} could not be renamed — delete it by hand; it is NOT a valid release."
        fi
    fi
    exit "$rc"
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
        SELFTEST_TARBALL="$tarball"
        trap mark_unverified_on_exit EXIT
        run_selftest "$tarball"
        trap - EXIT
        SELFTEST_TARBALL=""
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
