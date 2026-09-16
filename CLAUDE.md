# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A pure-bash toolchain that builds an offline, checksum-verified Apache Guacamole
deployment tarball on a connected machine (`build.sh`) and installs it on an
air-gapped Docker host (`bundle/install.sh`). No other languages, no jq — a
deliberate choice to keep the install side free of dependencies beyond Docker,
Compose v2, openssl and coreutils.

## Commands

```bash
bats tests/*.bats                                  # full test suite (~90 tests; all but one stub docker)
bats tests/build_images.bats                       # one file
bats tests/build_versions.bats --filter "digest"   # tests whose name matches a regex
shellcheck build.sh bundle/install.sh              # also enforced by tests/shellcheck.bats

./build.sh              # real build: needs internet + Docker, writes dist/*.tar.gz
./build.sh --selftest   # build, then unpack + install + HTTPS/API login check locally
                        # (binds host ports 80/443; a failed selftest renames the
                        #  tarball to *.tar.gz.FAILED)
./build.sh --run-local  # no build: stage bundle/ into a temp dir, compose up --wait,
                        # HTTPS/API login check, down -v. Fast check of bundle/ edits;
                        # needs Docker + ports 80/443, never touches dist/ or bundle/
```

`versions.env` in the repo has empty `*_DIGEST` values on purpose; a real build
requires filling them in (see README). Tests supply their own `versions.env`.

## Architecture

Two halves, one contract between them:

- **Build side** (`build.sh` + `versions.env`): pull each image *by digest*,
  re-tag it under its plain `repo:tag`, then `stage_bundle_tree` (copy
  `bundle/` in, strip builder-local `.env`/certs, run the webapp image's
  `initdb.sh` to generate `initdb/001-schema.sql`, substitute
  `__<COMPONENT>_IMAGE_REF__` placeholders in `docker-compose.yml`), then
  `docker save` by plain tag, write `provenance.txt`, then `manifest.sha256`
  last. `--run-local` reuses `stage_bundle_tree` and stops there: it brings
  the staged tree up directly (bypassing `install.sh`) and runs the same
  `verify_stack_responds` probes `--selftest` uses. `write_local_env` /
  `write_local_tls_cert` intentionally mirror `install.sh`'s
  `configure_env` / `generate_tls_cert` and must be kept in step.
- **Install side** (`bundle/` — everything here ships verbatim in the tarball):
  preflight → verify manifest + refuse unlisted files → `docker load` + confirm
  every compose image resolves → generate `.env` and self-signed TLS (idempotent)
  → `compose up` → wait for healthchecks.

Invariants that span both scripts — change one side, check the other:

- `versions.env` is the only place image references live. `COMPONENT_NAMES`
  in `build.sh` drives every loop; `bundle/docker-compose.yml` must carry one
  `__<NAME>_IMAGE_REF__` per component and nothing hardcoded.
- `compose_image_refs()` (the `awk '$1 == "image:"'` one-liner) is duplicated
  in both scripts intentionally so build-time and install-time agree on "the
  images this bundle needs". Compose `image:` values must stay unquoted.
- Manifest exclusions are mirrored: `write_manifest()` skips only
  `manifest.sha256`; `verify_no_unlisted_files()` additionally allow-lists
  `.env` and `nginx/certs/*` because install.sh creates them. Any new
  install-time-generated file must be added to that allow-list, and any new
  builder-local artifact must be stripped in `stage_bundle_tree()` (which
  already `rm -rf`s `.env` and `nginx/certs` from the bundle copy).
- The pull-by-digest → `docker tag` → save-by-plain-tag sequence is load-bearing:
  saving a `repo:tag@digest` ref produces `RepoTags:null` and an unaddressable
  image on the target. `assert_tar_repotags()` and
  `assert_compose_images_saved()` guard this at build time;
  `verify_compose_images_present()` guards it at install time.

## Bash conventions the code depends on

- Both scripts end with `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
  so tests can `source` them and call functions directly. Keep every path
  overridable via the `${VAR:-default}` env vars at the top of each script
  (`VERSIONS_FILE`, `BUNDLE_DIR`, `DIST_DIR`, `COMPOSE_FILE`, `IMAGES_DIR`,
  `CERT_DIR`, `ENV_FILE`, …) — that is how tests redirect I/O into
  `$BATS_TEST_TMPDIR`.
- Cleanup uses **subshell + EXIT trap**, never RETURN traps. RETURN traps are
  inherited by nested calls under bats' `set -T` and never fire on `exit`/`die`.
  `package_bundle` and `run_selftest` both document this in place; follow the
  same pattern for anything new that needs cleanup.
- bats' `run` helper does `set +eET`, so errexit is off inside anything called
  via `run`. That is why `package_bundle`'s subshell has an explicit `|| die`,
  and why `tests/build_selftest.bats` drives a real `bash` subprocess instead of
  `run main`. Don't put a subshell you rely on errexit inside on the left of
  `||`/`&&` or in an `if` — bash suppresses errexit inside it.
- Every failure goes through `die` with an actionable message that names the
  file/image/variable involved. Tests assert on substrings of those messages
  (`[[ "$output" == *"Failed to tag"* ]]`), so rewording an error is a test
  change too.

## Test layout

`tests/test_helper.bash` provides `stub_docker`, which puts a fake `docker` on
`PATH` that logs every invocation to `$DOCKER_LOG` and optionally delegates to
`$DOCKER_STUB_SCRIPT` (a bash script receiving the same args) to fake exit
codes, stdout, or side-effect files (e.g. writing a tar with a `manifest.json`
for `docker save`). `stub_curl` / `$CURL_LOG` / `$CURL_STUB_SCRIPT` are the
same shape for `curl`. One test (`bundle_config.bats`, `nginx -t`) needs a
real Docker daemon and the nginx image; it fails, not skips, without them.
Test files are named `build_*.bats` / `install_*.bats` by the function group
they cover. Always call `unstub_docker` in `teardown`.

Running `bundle/install.sh` in place inside the repo writes `bundle/.env` and
`bundle/nginx/certs/`; both are gitignored and stripped at package time.

## Docs

`docs/superpowers/specs/2026-09-14-offline-guacamole-design.md` is the design
rationale (scope, topology, security model); the matching `plans/` file is the
original task breakdown. Code comments referring to "Task N" point at that plan.
