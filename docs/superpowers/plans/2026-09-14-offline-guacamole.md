# Offline Guacamole Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a build-side toolchain (`build.sh`) that produces a self-contained, checksum-verified offline tarball for Apache Guacamole, and an install-side script (`install.sh`) that stands up a working Guacamole stack (nginx/TLS → guacamole webapp → guacd → Postgres) on a disconnected Docker host with zero outbound network access.

**Architecture:** Two independent bash scripts sharing no runtime dependency (`install.sh` is fully self-contained inside the shipped bundle). Both scripts are structured as a library of small, pure-ish functions plus a thin `main()`, guarded so bats-core can `source` each script and unit-test its functions without executing `main`. Docker Compose defines the four-container runtime topology; Postgres self-initializes from a schema file generated at build time directly from the pinned webapp image.

**Tech Stack:** bash (`set -euo pipefail`), Docker + Docker Compose v2, bats-core (shell unit tests), shellcheck (static analysis), openssl (secrets/certs), Apache Guacamole official images (`guacamole/guacamole`, `guacamole/guacd`), `postgres`, `nginx`.

## Global Constraints

- Target install host: Docker Engine + Docker Compose v2 on Ubuntu/Debian. Do not bundle or install a container runtime.
- User/connection storage: PostgreSQL-backed (no flat-file `user-mapping.xml`, no LDAP/AD).
- Bundle format: a single `.tar.gz` plus `install.sh` (not Zarf, not a registry archive).
- Web exposure: bundled nginx terminates TLS with a self-signed cert by default; nginx is the *only* container with published host ports (443, with 80 redirecting to 443).
- Build side is included and images are pinned by **tag and sha256 digest** in `versions.env`; the build must fail if a pull's resolved digest doesn't match.
- Out of scope for this plan: a Podman/RHEL variant, LDAP/AD auth, a bundled container-runtime installer, multi-host/HA, external reverse-proxy mode.
- Install-side preflight requires at least 2048 MB free disk under the Docker data root before proceeding.
- The default `guacadmin` / `guacadmin` account is a known fact of the generated schema — `install.sh` must print an explicit, hard-to-miss warning to change it after first login.
- Every script: `set -euo pipefail`; every failure path prints a specific, actionable message (what failed, how to fix it) rather than raw tool output.
- Both `build.sh` and `install.sh` must pass `shellcheck` with zero warnings before the plan is considered done.
- A tarball is only a valid release once `build.sh --selftest` (full install + health-wait + API login, against the tarball itself) passes.

---

### Task 1: Scaffold repository structure and bats-core test harness

**Files:**
- Create: `.gitignore`
- Create: `versions.env` (schema only — real digests filled in Task 2)
- Create: `bundle/.gitkeep` (removed once Task 7 adds real files — see note in Task 7)
- Create: `tests/test_helper.bash`
- Create: `tests/scaffold.bats`
- Modify: none

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `tests/test_helper.bash` exposing `stub_docker()` / `unstub_docker()`, used by every later bats file that needs to fake `docker` invocations.

- [ ] **Step 1: Install bats-core and shellcheck on the dev machine**

Run:
```bash
sudo apt-get update && sudo apt-get install -y bats shellcheck
```
Expected: both commands exit 0; `bats --version` and `shellcheck --version` print version strings.

- [ ] **Step 2: Create `.gitignore`**

```gitignore
/dist/
*.tar
*.tar.gz
.env
/nginx/certs/
*.log
```

- [ ] **Step 3: Create the `versions.env` schema (values filled in Task 2)**

```bash
# versions.env — pinned image references for the offline bundle.
# Every *_DIGEST value MUST be the real sha256 digest for the matching
# *_IMAGE:*_TAG, obtained with `docker inspect` after a real pull (see
# Task 2, Step 1). load_versions() in build.sh refuses to run if any
# digest here is not a well-formed sha256 digest.

GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=

GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=

POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=

NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=
```

- [ ] **Step 4: Create placeholder bundle directory so later tasks have somewhere to write**

```bash
mkdir -p bundle/nginx
touch bundle/.gitkeep
```

- [ ] **Step 5: Write the bats test-stub helper**

`tests/test_helper.bash`:
```bash
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
```

- [ ] **Step 6: Write a smoke test proving the harness works**

`tests/scaffold.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "stub_docker intercepts docker and logs its arguments" {
    stub_docker
    run docker pull hello:world
    [ "$status" -eq 0 ]
    grep -q "pull hello:world" "$DOCKER_LOG"
}
```

- [ ] **Step 7: Run the smoke test**

Run: `bats tests/scaffold.bats`
Expected: `1 test, 0 failures`

- [ ] **Step 8: Commit**

```bash
git add .gitignore versions.env bundle tests
git commit -m "chore: scaffold repo layout and bats-core test harness

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 2: `build.sh` — version pinning and image-reference resolution

**Files:**
- Create: `build.sh`
- Modify: `versions.env` (fill in real digests)
- Test: `tests/build_versions.bats`

**Interfaces:**
- Consumes: `tests/test_helper.bash` (`stub_docker`, `unstub_docker`) from Task 1.
- Produces: `load_versions(file)`, `image_ref(name)`, `all_component_names()`, `log_info(msg)`, `log_error(msg)`, `die(msg)` — sourced and reused by every later `build.sh` task.

- [ ] **Step 1: Obtain real digests for `versions.env` (requires network — dev machine only)**

Run, for each of the four images:
```bash
docker pull docker.io/guacamole/guacamole:1.6.0
docker inspect --format '{{index .RepoDigests 0}}' guacamole/guacamole:1.6.0
```
Copy the `sha256:...` part after the `@` into `GUACAMOLE_DIGEST` in `versions.env`. Repeat for `guacamole/guacd:1.6.0`, `postgres:16-alpine`, `nginx:1.27-alpine`, filling `GUACD_DIGEST`, `POSTGRES_DIGEST`, `NGINX_DIGEST`.

- [ ] **Step 2: Write the failing test**

`tests/build_versions.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VALID_VERSIONS="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VALID_VERSIONS" <<'EOF'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
}

@test "load_versions accepts a fully-populated, valid versions.env" {
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -eq 0 ]
}

@test "load_versions rejects a missing digest" {
    sed -i 's/^GUACD_DIGEST=.*/GUACD_DIGEST=/' "$VALID_VERSIONS"
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GUACD_DIGEST"* ]]
}

@test "load_versions rejects a malformed (non-sha256) digest" {
    sed -i 's/^NGINX_DIGEST=.*/NGINX_DIGEST=notadigest/' "$VALID_VERSIONS"
    source build.sh
    run load_versions "$VALID_VERSIONS"
    [ "$status" -ne 0 ]
    [[ "$output" == *"NGINX_DIGEST"* ]]
}

@test "image_ref renders repo:tag@digest" {
    source build.sh
    load_versions "$VALID_VERSIONS"
    result="$(image_ref GUACAMOLE)"
    [ "$result" = "guacamole/guacamole:1.6.0@sha256:1111111111111111111111111111111111111111111111111111111111111111" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/build_versions.bats`
Expected: FAIL — `build.sh: No such file or directory`

- [ ] **Step 3: Write `build.sh` (initial version — just this task's functions + sourcing guard)**

```bash
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "build.sh: not yet implemented past version loading" >&2
    exit 1
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/build_versions.bats`
Expected: `4 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add build.sh versions.env tests/build_versions.bats
git commit -m "feat(build): pin and validate image versions by digest

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 3: `build.sh` — `pull_images`

**Files:**
- Modify: `build.sh`
- Test: `tests/build_images.bats`

**Interfaces:**
- Consumes: `image_ref(name)`, `all_component_names()`, `log_info`, `die` from Task 2.
- Produces: `pull_images()` — called by `main()` in Task 6.

- [ ] **Step 1: Write the failing test**

`tests/build_images.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'EOF'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
}

teardown() {
    unstub_docker
}

@test "pull_images pulls all four images by digest reference" {
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -eq 0 ]
    grep -q "pull guacamole/guacamole:1.6.0@sha256:1111" "$DOCKER_LOG"
    grep -q "pull guacamole/guacd:1.6.0@sha256:2222" "$DOCKER_LOG"
    grep -q "pull postgres:16-alpine@sha256:3333" "$DOCKER_LOG"
    grep -q "pull nginx:1.27-alpine@sha256:4444" "$DOCKER_LOG"
}

@test "pull_images fails loudly if a pull fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1 $2" == "pull guacamole/guacd:1.6.0@sha256:2222222222222222222222222222222222222222222222222222222222222222" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run pull_images
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/build_images.bats`
Expected: FAIL — `pull_images: command not found`

- [ ] **Step 3: Implement `pull_images` in `build.sh`** (insert after `image_ref`, before the sourcing guard)

```bash
pull_images() {
    local name ref
    for name in $(all_component_names); do
        ref="$(image_ref "$name")"
        log_info "Pulling ${ref}"
        docker pull "${ref}"
    done
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/build_images.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add build.sh tests/build_images.bats
git commit -m "feat(build): pull pinned images by digest

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 4: `build.sh` — `generate_schema`

**Files:**
- Modify: `build.sh`
- Test: `tests/build_schema.bats`

**Interfaces:**
- Consumes: `image_ref(name)`, `die`, `log_info` from Task 2.
- Produces: `generate_schema(out_dir)` — writes `$out_dir/001-schema.sql`; called by `package_bundle()` in Task 6.

- [ ] **Step 1: Write the failing test**

`tests/build_schema.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'EOF'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
}

teardown() {
    unstub_docker
}

@test "generate_schema runs initdb.sh in the guacamole image and writes 001-schema.sql" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    out_dir="$BATS_TEST_TMPDIR/initdb"
    run generate_schema "$out_dir"
    [ "$status" -eq 0 ]
    [ -s "$out_dir/001-schema.sql" ]
    grep -q "fake schema" "$out_dir/001-schema.sql"
    grep -q "run --rm guacamole/guacamole:1.6.0@sha256:1111" "$DOCKER_LOG"
}

@test "generate_schema dies if the generated file is empty" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run generate_schema "$BATS_TEST_TMPDIR/initdb2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"empty"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/build_schema.bats`
Expected: FAIL — `generate_schema: command not found`

- [ ] **Step 3: Implement `generate_schema`**

```bash
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
        > "$out_dir/001-schema.sql"
    [[ -s "$out_dir/001-schema.sql" ]] \
        || die "schema generation produced an empty file — check 'docker run --rm ${guac_ref} /opt/guacamole/bin/initdb.sh --postgresql' manually"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/build_schema.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Verify the real path against the actual pulled image (dev machine, one-time check)**

Run:
```bash
docker run --rm guacamole/guacamole:1.6.0 /opt/guacamole/bin/initdb.sh --postgresql | head -5
```
Expected: valid-looking SQL (`CREATE TABLE ...`) on stdout. If the path differs, update the `docker run` path in Step 3 and re-run Step 4.

- [ ] **Step 6: Commit**

```bash
git add build.sh tests/build_schema.bats
git commit -m "feat(build): generate Postgres schema from the pinned webapp image

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 5: `build.sh` — `save_images` and `write_manifest`

**Files:**
- Modify: `build.sh`
- Test: `tests/build_manifest.bats`

**Interfaces:**
- Consumes: `image_ref`, `all_component_names`, `log_info`, `die` from Task 2.
- Produces: `save_images(out_dir)`, `write_manifest(root_dir)` — called by `package_bundle()` in Task 6.

- [ ] **Step 1: Write the failing test**

`tests/build_manifest.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'EOF'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
}

teardown() {
    unstub_docker
}

@test "save_images saves each image to a lowercase-named tar" {
    stub_docker
    source build.sh
    load_versions "$VERSIONS_FILE"
    out_dir="$BATS_TEST_TMPDIR/images"
    run save_images "$out_dir"
    [ "$status" -eq 0 ]
    grep -q "save guacamole/guacamole:1.6.0@sha256:1111.*-o ${out_dir}/guacamole.tar" "$DOCKER_LOG"
    grep -q "save guacamole/guacd:1.6.0@sha256:2222.*-o ${out_dir}/guacd.tar" "$DOCKER_LOG"
    grep -q "save postgres:16-alpine@sha256:3333.*-o ${out_dir}/postgres.tar" "$DOCKER_LOG"
    grep -q "save nginx:1.27-alpine@sha256:4444.*-o ${out_dir}/nginx.tar" "$DOCKER_LOG"
}

@test "write_manifest writes a checksum for every file except itself" {
    root="$BATS_TEST_TMPDIR/root"
    mkdir -p "$root/images" "$root/initdb"
    echo "a" > "$root/images/guacamole.tar"
    echo "b" > "$root/initdb/001-schema.sql"
    source build.sh
    write_manifest "$root"
    [ -f "$root/manifest.sha256" ]
    run sha256sum -c "$root/manifest.sha256"
    cd "$root" && run sha256sum -c manifest.sha256
    [ "$status" -eq 0 ]
    ! grep -q "manifest.sha256" "$root/manifest.sha256"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/build_manifest.bats`
Expected: FAIL — `save_images: command not found`

- [ ] **Step 3: Implement both functions**

```bash
save_images() {
    local out_dir="$1" name ref safe_name
    mkdir -p "$out_dir"
    for name in $(all_component_names); do
        ref="$(image_ref "$name")"
        safe_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        log_info "Saving ${ref} -> ${out_dir}/${safe_name}.tar"
        docker save "${ref}" -o "${out_dir}/${safe_name}.tar"
    done
}

write_manifest() {
    local root_dir="$1"
    (
        cd "$root_dir"
        find . -type f ! -name 'manifest.sha256' -print0 \
            | sort -z \
            | xargs -0 sha256sum
    ) > "$root_dir/manifest.sha256"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/build_manifest.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add build.sh tests/build_manifest.bats
git commit -m "feat(build): save images and write a whole-bundle checksum manifest

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 6: `build.sh` — `package_bundle` and `main()` orchestration

**Files:**
- Modify: `build.sh`
- Test: `tests/build_package.bats`

**Interfaces:**
- Consumes: `generate_schema`, `save_images`, `write_manifest`, `load_versions`, `die`, `log_info`, `BUNDLE_DIR`, `DIST_DIR` from Tasks 2–5.
- Produces: `package_bundle(version)` (returns the tarball path on stdout), `main()` — `main` is the script's CLI entry point (`./build.sh [version] [--selftest]`), consumed by Task 15's selftest.

- [ ] **Step 1: Write the failing test**

`tests/build_package.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export VERSIONS_FILE="$BATS_TEST_TMPDIR/versions.env"
    cat > "$VERSIONS_FILE" <<'EOF'
GUACAMOLE_IMAGE=guacamole/guacamole
GUACAMOLE_TAG=1.6.0
GUACAMOLE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
GUACD_IMAGE=guacamole/guacd
GUACD_TAG=1.6.0
GUACD_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
POSTGRES_IMAGE=postgres
POSTGRES_TAG=16-alpine
POSTGRES_DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
NGINX_IMAGE=nginx
NGINX_TAG=1.27-alpine
NGINX_DIGEST=sha256:4444444444444444444444444444444444444444444444444444444444444444
EOF
    export BUNDLE_DIR="$BATS_TEST_TMPDIR/bundle"
    mkdir -p "$BUNDLE_DIR/nginx"
    echo "compose" > "$BUNDLE_DIR/docker-compose.yml"
    echo "install" > "$BUNDLE_DIR/install.sh"
    export DIST_DIR="$BATS_TEST_TMPDIR/dist"
}

teardown() {
    unstub_docker
}

@test "package_bundle produces a checksummed, self-consistent tarball" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    echo "-- fake schema"
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    tarball="$(package_bundle "1.6.0")"
    [ -f "$tarball" ]
    [[ "$tarball" == "$DIST_DIR"/guacamole-offline-1.6.0-*.tar.gz ]]

    extract_dir="$BATS_TEST_TMPDIR/extracted"
    mkdir -p "$extract_dir"
    tar -xzf "$tarball" -C "$extract_dir"
    root="$extract_dir/guacamole-offline-1.6.0"
    [ -f "$root/docker-compose.yml" ]
    [ -f "$root/install.sh" ]
    [ -f "$root/initdb/001-schema.sql" ]
    [ -f "$root/images/guacamole.tar" ]
    [ -f "$root/manifest.sha256" ]
    (cd "$root" && sha256sum -c manifest.sha256)
}

@test "package_bundle leaves no partial tarball in dist/ if schema generation fails" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
if [[ "$1" == "run" ]]; then
    exit 1
fi
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    source build.sh
    load_versions "$VERSIONS_FILE"
    run package_bundle "1.6.0"
    [ "$status" -ne 0 ]
    [ ! -d "$DIST_DIR" ] || [ -z "$(ls -A "$DIST_DIR" 2>/dev/null)" ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/build_package.bats`
Expected: FAIL — `package_bundle: command not found`

- [ ] **Step 3: Implement `package_bundle` and `main`**

```bash
package_bundle() {
    local version="$1" work_dir root date_stamp tarball_name
    date_stamp="$(date -u +%Y%m%d)"
    tarball_name="guacamole-offline-${version}-${date_stamp}.tar.gz"

    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/guac-build.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$work_dir'" RETURN

    root="$work_dir/guacamole-offline-${version}"
    mkdir -p "$root/images" "$root/initdb"
    cp -a "$BUNDLE_DIR"/. "$root/"

    generate_schema "$root/initdb"
    save_images "$root/images"
    write_manifest "$root"

    mkdir -p "$DIST_DIR"
    tar -C "$work_dir" -czf "$DIST_DIR/${tarball_name}.partial" "guacamole-offline-${version}"
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
```

Replace the old placeholder sourcing guard at the bottom of `build.sh` with:
```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

(`run_selftest` is defined in Task 15 — until then, leave a real function stub that dies clearly:)
```bash
run_selftest() {
    die "run_selftest is not implemented yet (see Task 15)"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/build_package.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Run the full build.sh test suite to confirm nothing regressed**

Run: `bats tests/build_*.bats`
Expected: all tests across all four files pass.

- [ ] **Step 6: Commit**

```bash
git add build.sh tests/build_package.bats
git commit -m "feat(build): assemble and atomically publish the offline tarball

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 7: Bundle static configuration — `docker-compose.yml`, `nginx.conf`, `env.template`

**Files:**
- Create: `bundle/docker-compose.yml`
- Create: `bundle/nginx/nginx.conf`
- Create: `bundle/env.template`
- Modify: remove `bundle/.gitkeep` (real content now present)
- Test: `tests/bundle_config.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks (static files).
- Produces: `docker-compose.yml` service names `postgres`, `guacd`, `guacamole`, `nginx` and their healthchecks — consumed by `wait_healthy()` in Task 13. `env.template`'s `__POSTGRES_PASSWORD__` marker — consumed by `configure_env()` in Task 11.

- [ ] **Step 1: Write the failing test**

`tests/bundle_config.bats`:
```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/bundle_config.bats`
Expected: FAIL — compose file not found.

- [ ] **Step 3: Write `bundle/docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:${POSTGRES_TAG:-16-alpine}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - guac-db:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [guac-net]

  guacd:
    image: guacamole/guacd:${GUACD_TAG:-1.6.0}
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/4822' || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [guac-net]

  guacamole:
    image: guacamole/guacamole:${GUACAMOLE_TAG:-1.6.0}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      guacd:
        condition: service_healthy
    environment:
      GUACD_HOSTNAME: guacd
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_DATABASE: ${POSTGRES_DB}
      POSTGRESQL_USER: ${POSTGRES_USER}
      POSTGRESQL_PASSWORD: ${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://127.0.0.1:8080/guacamole/ >/dev/null || exit 1"]
      interval: 5s
      timeout: 5s
      retries: 30
    networks: [guac-net]

  nginx:
    image: nginx:${NGINX_TAG:-1.27-alpine}
    restart: unless-stopped
    depends_on:
      guacamole:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
    healthcheck:
      test: ["CMD", "wget", "--no-check-certificate", "-q", "-O", "-", "https://127.0.0.1/guacamole/"]
      interval: 5s
      timeout: 5s
      retries: 20
    networks: [guac-net]

networks:
  guac-net:
    driver: bridge

volumes:
  guac-db:
```

- [ ] **Step 4: Write `bundle/nginx/nginx.conf`**

```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 80;
        server_name _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;

        location = / {
            return 301 /guacamole/;
        }

        location /guacamole/ {
            proxy_pass         http://guacamole:8080/guacamole/;
            proxy_buffering    off;
            proxy_http_version 1.1;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            proxy_cookie_path /guacamole/ /;
        }
    }
}
```

- [ ] **Step 5: Write `bundle/env.template`**

```
POSTGRES_DB=guacamole_db
POSTGRES_USER=guacamole
POSTGRES_PASSWORD=__POSTGRES_PASSWORD__
```

- [ ] **Step 6: Remove the placeholder file**

```bash
git rm bundle/.gitkeep
```

- [ ] **Step 7: Run to verify the tests pass**

Run: `bats tests/bundle_config.bats`
Expected: `4 tests, 0 failures`

If the `guacd` or `guacamole` healthcheck fails against the real pulled images (e.g. `wget`/`bash` not present in that image's base), adjust the `test:` command to a tool confirmed present in the image (check with `docker run --rm <image> sh -c 'which wget bash nc curl'`) and re-run this step.

- [ ] **Step 8: Commit**

```bash
git add bundle tests/bundle_config.bats
git commit -m "feat(bundle): add compose stack, nginx TLS config, and env template

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 8: `install.sh` — logging helpers and `preflight_checks`

**Files:**
- Create: `bundle/install.sh`
- Test: `tests/install_preflight.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks (`install.sh` is self-contained; no sourcing of `build.sh` or shared libs).
- Produces: `log_info`, `log_error`, `die`, `check_docker`, `check_compose`, `check_ports_free`, `check_disk_space(dir)`, `preflight_checks()` — reused by later `install.sh` tasks and called first from `main()` in Task 13.

- [ ] **Step 1: Write the failing test**

`tests/install_preflight.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "check_docker dies with an actionable message if docker is missing" {
    export PATH="/usr/bin:/bin"  # docker deliberately not stubbed onto PATH
    source bundle/install.sh
    run check_docker
    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker"* ]]
}

@test "check_docker passes when docker is present and the daemon responds" {
    stub_docker
    source bundle/install.sh
    run check_docker
    [ "$status" -eq 0 ]
}

@test "check_disk_space dies with an actionable message when space is insufficient" {
    source bundle/install.sh
    MIN_FREE_MB=999999999
    run check_disk_space "$BATS_TEST_TMPDIR"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MB free"* ]]
}

@test "check_disk_space passes when space is sufficient" {
    source bundle/install.sh
    MIN_FREE_MB=1
    run check_disk_space "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_preflight.bats`
Expected: FAIL — `bundle/install.sh: No such file or directory`

- [ ] **Step 3: Write `bundle/install.sh`**

```bash
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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "install.sh: not yet fully implemented" >&2
    exit 1
fi
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_preflight.bats`
Expected: `4 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add bundle/install.sh tests/install_preflight.bats
git commit -m "feat(install): add logging helpers and host preflight checks

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 9: `install.sh` — `verify_manifest`

**Files:**
- Modify: `bundle/install.sh`
- Test: `tests/install_manifest.bats`

**Interfaces:**
- Consumes: `log_info`, `log_error`, `die` from Task 8.
- Produces: `verify_manifest(root)` — called second from `main()` in Task 13.

- [ ] **Step 1: Write the failing test**

`tests/install_manifest.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

setup() {
    export ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$ROOT/images"
    echo "abc" > "$ROOT/images/guacamole.tar"
    (cd "$ROOT" && sha256sum images/guacamole.tar > manifest.sha256)
}

@test "verify_manifest passes when every file matches its checksum" {
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -eq 0 ]
}

@test "verify_manifest dies and names the file when a checksum mismatches" {
    echo "tampered" > "$ROOT/images/guacamole.tar"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"guacamole.tar"* ]]
}

@test "verify_manifest dies with an actionable message when manifest.sha256 is missing" {
    rm "$ROOT/manifest.sha256"
    source bundle/install.sh
    run verify_manifest "$ROOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"manifest.sha256"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_manifest.bats`
Expected: FAIL — `verify_manifest: command not found`

- [ ] **Step 3: Implement `verify_manifest`** (insert after `preflight_checks`)

```bash
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_manifest.bats`
Expected: `3 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add bundle/install.sh tests/install_manifest.bats
git commit -m "feat(install): verify bundle integrity against manifest.sha256

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 10: `install.sh` — `configure_env`

**Files:**
- Modify: `bundle/install.sh`
- Test: `tests/install_env.bats`

**Interfaces:**
- Consumes: `log_info`, `die`, `ENV_FILE`, `ENV_TEMPLATE` from Task 8; the `__POSTGRES_PASSWORD__` marker from Task 7's `env.template`.
- Produces: `configure_env()` — called from `main()` in Task 13; writes `$ENV_FILE`.

- [ ] **Step 1: Write the failing test**

`tests/install_env.bats`:
```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_env.bats`
Expected: FAIL — `configure_env: command not found`

- [ ] **Step 3: Implement `configure_env`** (insert after `verify_manifest`)

```bash
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_env.bats`
Expected: `3 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add bundle/install.sh tests/install_env.bats
git commit -m "feat(install): generate .env with a random Postgres password on first run

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 11: `install.sh` — `generate_tls_cert`

**Files:**
- Modify: `bundle/install.sh`
- Test: `tests/install_tls.bats`

**Interfaces:**
- Consumes: `log_info`, `CERT_DIR` from Task 8.
- Produces: `generate_tls_cert()` — called from `main()` in Task 13; writes `$CERT_DIR/fullchain.pem` and `$CERT_DIR/privkey.pem`, consumed by nginx's compose mount (Task 7).

- [ ] **Step 1: Write the failing test**

`tests/install_tls.bats`:
```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_tls.bats`
Expected: FAIL — `generate_tls_cert: command not found`

- [ ] **Step 3: Implement `generate_tls_cert`** (insert after `configure_env`)

```bash
generate_tls_cert() {
    local cert="$CERT_DIR/fullchain.pem" key="$CERT_DIR/privkey.pem"
    if [[ -f "$cert" && -f "$key" ]]; then
        log_info "TLS certificate already present at ${CERT_DIR} — leaving it in place"
        return 0
    fi
    mkdir -p "$CERT_DIR"
    log_info "Generating a self-signed TLS certificate (365 days) at ${CERT_DIR}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$key" -out "$cert" -days 365 \
        -subj "/CN=guacamole.local" \
        >/dev/null 2>&1
    chmod 600 "$key"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_tls.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add bundle/install.sh tests/install_tls.bats
git commit -m "feat(install): generate a self-signed TLS cert unless one is provided

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 12: `install.sh` — `load_images`

**Files:**
- Modify: `bundle/install.sh`
- Test: `tests/install_load_images.bats`

**Interfaces:**
- Consumes: `log_info`, `die`, `IMAGES_DIR` from Task 8.
- Produces: `load_images()` — called from `main()` in Task 13.

- [ ] **Step 1: Write the failing test**

`tests/install_load_images.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "load_images loads every tar in IMAGES_DIR" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/images"
    mkdir -p "$IMAGES_DIR"
    touch "$IMAGES_DIR/guacamole.tar" "$IMAGES_DIR/guacd.tar"
    stub_docker
    source bundle/install.sh
    run load_images
    [ "$status" -eq 0 ]
    grep -q "load -i ${IMAGES_DIR}/guacamole.tar" "$DOCKER_LOG"
    grep -q "load -i ${IMAGES_DIR}/guacd.tar" "$DOCKER_LOG"
}

@test "load_images dies with an actionable message when no tars are present" {
    export IMAGES_DIR="$BATS_TEST_TMPDIR/empty_images"
    mkdir -p "$IMAGES_DIR"
    stub_docker
    source bundle/install.sh
    run load_images
    [ "$status" -ne 0 ]
    [[ "$output" == *"No image tars found"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_load_images.bats`
Expected: FAIL — `load_images: command not found`

- [ ] **Step 3: Implement `load_images`** (insert after `generate_tls_cert`)

```bash
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_load_images.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Commit**

```bash
git add bundle/install.sh tests/install_load_images.bats
git commit -m "feat(install): load bundled image tars into the local Docker daemon

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 13: `install.sh` — `compose_up`, `wait_healthy`, `print_summary`, `main()`

**Files:**
- Modify: `bundle/install.sh`
- Test: `tests/install_orchestration.bats`

**Interfaces:**
- Consumes: every function from Tasks 8–12; `docker-compose.yml` service names from Task 7.
- Produces: `main()` — the script's CLI entry point (`./install.sh`), consumed by Task 15's selftest.

- [ ] **Step 1: Write the failing test**

`tests/install_orchestration.bats`:
```bash
#!/usr/bin/env bats

load 'test_helper'

teardown() {
    unstub_docker
}

@test "wait_healthy returns 0 once docker compose ps reports every service healthy" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
args="$*"
case "$args" in
    "compose -f "*" config --services")
        printf 'postgres\nguacd\nguacamole\nnginx\n'
        ;;
    "compose -f "*" ps -q "*)
        echo "fakecontainerid"
        ;;
    "inspect --format "*)
        echo "healthy"
        ;;
esac
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    touch "$COMPOSE_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run wait_healthy 10
    [ "$status" -eq 0 ]
}

@test "wait_healthy times out and reports status when a service never becomes healthy" {
    stub_docker
    cat > "$STUB_BIN_DIR/docker_stub_script.sh" <<'EOF'
args="$*"
case "$args" in
    "compose -f "*" config --services")
        printf 'postgres\nguacd\nguacamole\nnginx\n'
        ;;
    "compose -f "*" ps -q "*)
        echo "fakecontainerid"
        ;;
    "inspect --format "*)
        echo "starting"
        ;;
    "compose -f "*" ps")
        echo "fake ps output"
        ;;
esac
exit 0
EOF
    export DOCKER_STUB_SCRIPT="$STUB_BIN_DIR/docker_stub_script.sh"
    export COMPOSE_FILE="$BATS_TEST_TMPDIR/docker-compose.yml"
    touch "$COMPOSE_FILE"
    source bundle/install.sh
    SCRIPT_DIR="$BATS_TEST_TMPDIR"
    run wait_healthy 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"Timed out"* ]]
    [[ "$output" == *"docker compose logs"* ]]
}

@test "print_summary mentions the default guacadmin credentials and a change warning" {
    source bundle/install.sh
    run print_summary
    [[ "$output" == *"guacadmin"* ]]
    [[ "$output" == *"CHANGE"* ]]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/install_orchestration.bats`
Expected: FAIL — `wait_healthy: command not found`

- [ ] **Step 3: Implement `compose_up`, `wait_healthy`, `print_summary`, and `main`** (insert after `load_images`, replacing the old placeholder guard)

```bash
compose_up() {
    ( cd "$SCRIPT_DIR" && docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d )
}

wait_healthy() {
    local timeout="${1:-180}" elapsed=0 services svc cid status unhealthy

    services="$(cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" config --services)"
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/install_orchestration.bats`
Expected: `3 tests, 0 failures`

- [ ] **Step 5: Run the full install.sh test suite to confirm nothing regressed**

Run: `bats tests/install_*.bats`
Expected: all tests across all five install test files pass.

- [ ] **Step 6: Commit**

```bash
git add bundle/install.sh tests/install_orchestration.bats
git commit -m "feat(install): bring the stack up, wait for health, and report the result

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 14: Static analysis — shellcheck clean on both scripts

**Files:**
- Modify: `build.sh`, `bundle/install.sh` (only as needed to clear warnings)
- Create: `tests/shellcheck.bats`

**Interfaces:**
- Consumes: the finished `build.sh` (Task 6) and `bundle/install.sh` (Task 13).
- Produces: nothing new — a verification gate only.

- [ ] **Step 1: Write the failing test**

`tests/shellcheck.bats`:
```bash
#!/usr/bin/env bats

@test "build.sh is shellcheck-clean" {
    run shellcheck build.sh
    [ "$status" -eq 0 ]
}

@test "bundle/install.sh is shellcheck-clean" {
    run shellcheck bundle/install.sh
    [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to see the current state**

Run: `bats tests/shellcheck.bats`
Expected: likely FAIL initially (shellcheck commonly flags things like unquoted `$@` in usage strings or `SC2155` on `local x="$(...)"` declarations).

- [ ] **Step 3: Fix every reported warning**

Run `shellcheck build.sh` and `shellcheck bundle/install.sh` directly, and address each finding — typically:
- Split `local var="$(cmd)"` into `local var; var="$(cmd)"` (SC2155) wherever shellcheck flags it.
- Add `# shellcheck disable=SC1090` (already present on the two `source` calls) if shellcheck still complains, or replace with `# shellcheck source=/dev/null`.
- Quote any remaining unquoted expansions shellcheck flags.

Do not blanket-disable a warning class — fix the underlying code first; only add a targeted `disable` comment when the flagged pattern is intentional (as with the two dynamic `source` calls).

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/shellcheck.bats`
Expected: `2 tests, 0 failures`

- [ ] **Step 5: Re-run the full unit test suite to confirm fixes didn't break behavior**

Run: `bats tests/*.bats`
Expected: every test file passes (the two integration-style bundle_config tests still require Docker/openssl locally, as before).

- [ ] **Step 6: Commit**

```bash
git add build.sh bundle/install.sh tests/shellcheck.bats
git commit -m "chore: make both scripts shellcheck-clean

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

### Task 15: `build.sh --selftest` integration test, README docs, and release gate

**Files:**
- Modify: `build.sh` (replace the `run_selftest` stub from Task 6 with a real implementation)
- Create: `README.md`
- Create: `bundle/README.md`

**Interfaces:**
- Consumes: `main()` and `package_bundle()` from `build.sh` (Task 6); `main()` from `bundle/install.sh` (Task 13); requires a real Docker daemon and real network access to the four pinned registries (this task cannot be meaningfully unit-tested with stubs — it is the end-to-end proof the whole system works).
- Produces: a working `guacamole-offline-<ver>-<date>.tar.gz` in `dist/`, proven installable, as the final deliverable of this plan.

- [ ] **Step 1: Implement `run_selftest` in `build.sh`**, replacing the Task 6 stub:

```bash
run_selftest() {
    local tarball="$1" extract_dir root

    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/guac-selftest.XXXXXX")"
    trap 'rm -rf "$extract_dir"; ( cd "$root" 2>/dev/null && docker compose -f docker-compose.yml down -v ) 2>/dev/null || true' RETURN

    log_info "Selftest: extracting $tarball"
    tar -xzf "$tarball" -C "$extract_dir"
    root="$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | head -1)"

    log_info "Selftest: running install.sh against the extracted bundle"
    ( cd "$root" && ./install.sh )

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
}
```

- [ ] **Step 2: Run the selftest against a real build (requires internet + Docker; run on the dev machine, not in a sandboxed CI runner without Docker)**

Run: `./build.sh --selftest`
Expected: build completes, `install.sh` runs to completion inside the selftest, `Selftest passed: ...` is the final line, exit code 0.

If it fails at the health-wait step, run `docker compose -f <extracted-root>/docker-compose.yml logs <service>` as the script suggests, fix the root cause (commonly: a healthcheck command Step 7 of Task 7 flagged as needing adjustment for the real image), and re-run.

- [ ] **Step 3: Write the top-level `README.md`**

```markdown
# offline-guacamole

Build an offline, checksum-verified [Apache Guacamole](https://guacamole.apache.org/)
deployment bundle, and install it on a Docker host with no internet access.

## Building a release (needs internet + Docker)

1. Edit `versions.env` to pin the Guacamole/guacd/Postgres/nginx versions you want.
   For each image, run:
   ```bash
   docker pull docker.io/<image>:<tag>
   docker inspect --format '{{index .RepoDigests 0}}' <image>:<tag>
   ```
   and copy the `sha256:...` digest into the matching `*_DIGEST` line.
2. Run `./build.sh --selftest`. This pulls the pinned images, generates the
   Postgres schema from the real webapp image, packages everything into
   `dist/guacamole-offline-<version>-<date>.tar.gz`, and proves the result
   installs and comes up healthy before leaving it in `dist/`.
3. Copy that tarball to the disconnected target by whatever transfer process
   your environment uses (removable media, a one-way diode, etc).

## Installing on the disconnected target (needs Docker + Compose v2 only)

```bash
tar -xzf guacamole-offline-<version>-<date>.tar.gz
cd guacamole-offline-<version>
./install.sh
```

`install.sh` verifies the bundle's integrity, loads the images, generates a
random database password and a self-signed TLS certificate (unless you've
already placed your own `fullchain.pem`/`privkey.pem` in `nginx/certs/`
beforehand), brings the stack up, and waits for it to report healthy. It is
safe to re-run — an existing `.env` or certificate is left untouched.

**Change the default `guacadmin` / `guacadmin` password immediately after
first login.**

## Development

```bash
sudo apt-get install -y bats shellcheck
bats tests/*.bats
shellcheck build.sh bundle/install.sh
```

See `docs/superpowers/specs/2026-09-14-offline-guacamole-design.md` for the
full design rationale.
```

- [ ] **Step 4: Write `bundle/README.md`** (ships inside the tarball itself, for someone with no other context)

```markdown
# Guacamole — offline install

## Install

```bash
./install.sh
```

Requires Docker Engine and Docker Compose v2 already installed on this host.
No internet access is used or required.

## What this does

1. Verifies every file in this bundle against `manifest.sha256`.
2. Loads the four bundled container images into the local Docker daemon.
3. Generates `.env` (random database password) and a self-signed TLS
   certificate, unless they already exist — safe to re-run.
4. Starts Postgres, guacd, the Guacamole webapp, and nginx, and waits for
   all four to report healthy.

## After install

Browse to `https://<this-host>/guacamole/` and log in as `guacadmin` /
`guacadmin`. **Change that password immediately** (Settings -> Users ->
guacadmin -> change password).

## Troubleshooting

If `install.sh` times out waiting for services to become healthy, it prints
the exact `docker compose logs <service>` command to run for each service —
run those first.

To supply your own TLS certificate instead of the generated self-signed one,
place `fullchain.pem` and `privkey.pem` in `nginx/certs/` before running
`install.sh` (or replace them and run `docker compose restart nginx`
afterward).
```

- [ ] **Step 5: Commit**

```bash
git add build.sh README.md bundle/README.md
git commit -m "feat(build): add end-to-end selftest as the release gate; add docs

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UAb5tKP2YWzrhzAoaKLrEv"
```

---

## Plan Self-Review

**Spec coverage:**
- §2.1/§2.2 repo & bundle layout → Task 1 (repo scaffold), Task 7 (bundle files), Task 6 (`package_bundle` assembles the exact bundle tree).
- §2.3 runtime topology (4 services, internal-only except nginx, named Postgres volume, schema auto-init) → Task 7 (`docker-compose.yml`).
- §3 build-side behavior (digest pinning, digest pull, schema capture, save, manifest, atomic packaging) → Tasks 2–6.
- §3.1 `build.sh --selftest` release gate → Task 15.
- §4 install-side behavior (preflight, integrity check, load, first-run secrets, first-run cert, up, health wait, report) → Tasks 8–13, in the same order as the spec.
- §5 error handling (`set -euo pipefail`, specific messages, named failing checksum file, per-service logs command on timeout) → present in every task's implementation and directly asserted in the corresponding bats tests.
- §6 testing (shellcheck, selftest as release gate, health-wait as target acceptance) → Task 14 (shellcheck) and Task 15 (selftest = both the release gate and, by the same mechanism, a proof the target-side acceptance check works).
- §7 (no open items; deferred scope: Podman/RHEL, LDAP/AD, external proxy) → reflected in Global Constraints; no tasks touch these areas.

**Placeholder scan:** No "TBD"/"TODO"/"implement later" remain. The two spots that depend on live registry/image inspection (`versions.env` digests in Task 2 Step 1; the `initdb.sh` path verification in Task 4 Step 5, and the healthcheck command verification in Task 7 Step 7) are each a concrete, executable command with a stated expected result and a stated corrective action if reality differs — not vague deferrals.

**Type/interface consistency:** Verified function names and call sites match across tasks: `load_versions`/`image_ref`/`all_component_names` (Task 2) are used identically in Tasks 3–6; `generate_schema`/`save_images`/`write_manifest` (Tasks 4–5) are called with the same signatures from `package_bundle` (Task 6); `preflight_checks`/`verify_manifest`/`configure_env`/`generate_tls_cert`/`load_images` (Tasks 8–12) are each called with no arguments from `main()` in Task 13, matching how each was defined; `wait_healthy` is called as `wait_healthy 180` in Task 13's `main`, matching its `timeout="${1:-180}"` signature from the same task.

**Scope check:** Single subsystem (one deployable bundle), no decomposition needed — matches the spec's own scope statement.
