# Plan: Local Pre-Package Stack Check

**Source PRD**: .claude/prds/local-prepackage-check.prd.md
**Selected Milestone**: 1 — Run the working-tree bundle locally
**Complexity**: Medium

## Summary
Add `build.sh --run-local`: pull the pinned images (a no-op when cached),
stage the working-tree `bundle/` into a temp dir exactly as packaging does
(copy, strip secrets, generate schema, substitute image placeholders), then
bring that tree up with `docker compose up --wait`, probe the HTTPS login
page and the `guacadmin` API login, and tear down with `down -v` on every
exit path. No `docker save`, no tarball, no writes into `bundle/` or `dist/`.
The staging step is factored out of `package_bundle` so both paths share one
definition of "what the bundle contains"; the HTTP probes are factored out of
`run_selftest` so both paths share one verification bar.

## Decisions on the PRD's open questions
| Question | Decision | Why |
|---|---|---|
| Image resolution | Run `pull_images` first, same as a build | `docker pull` by digest is a fast no-op when already local, and it is the step that guarantees the plain `repo:tag` the compose file names exists. No new "already present" mode to maintain. |
| Ports 80/443 | Keep them; fail clearly if busy | Alternate ports would need a compose override file and a second nginx listen config — not worth it for the MVP. Compose's port-binding error is explicit. Deferred, noted in Risks. |
| Reuse vs. bypass `install.sh` | Bypass; stage into a temp tree | Running `install.sh` in place needs image tars (`load_images` dies without them) and writes `bundle/.env`/certs into the working tree. Sourcing its functions collides with build.sh's own `die`/`log_*`/`compose_image_refs`. `install.sh` stays covered by `--selftest`. |
| Part of `bats tests/*.bats`? | The function is unit-tested with the stubbed docker; the real end-to-end run is manual | Matches the existing split: `--selftest` is also only stub-tested in bats. |
| Podman | No | Docker + Compose v2 only, as the rest of the repo. |

## Patterns to Mirror
| Category | Source | Pattern |
|---|---|---|
| Naming | `build.sh:378` | Long flags parsed in `main`'s `case`; snake_case verb functions (`pull_images`, `run_selftest`) |
| Errors | `build.sh:66`, `build.sh:330` | `cmd \|\| die "what failed — why it matters — what to check"`; every failure names the file/image involved |
| Logging | `build.sh:11` | `log_info "Selftest: ..."` step narration to stderr; prefix the new step `Run-local:` |
| Cleanup | `build.sh:238`, `build.sh:319` | Body in a `( … )` subshell with an EXIT trap doing `rm -rf` + `docker compose down -v`; never a RETURN trap |
| Staging | `build.sh:242-255` | `cp -a "$BUNDLE_DIR"/. "$root/"` then `rm -rf "$root/.env" "$root/nginx/certs"` before anything else |
| Secrets/TLS | `bundle/install.sh:139-146`, `:167` | `openssl rand -base64 24` + `sed "s\|__POSTGRES_PASSWORD__\|…\|"` under `umask 077`; `openssl req -x509 -nodes -newkey rsa:2048 … -subj /CN=guacamole.local` |
| Health wait | `bundle/install.sh:230` (do NOT copy) | Use `docker compose up -d --wait --wait-timeout 180` instead — Compose v2 does what `wait_healthy` does; no duplicated polling loop |
| Tests: function-level | `tests/build_package.bats:45-63` | `stub_docker` + `DOCKER_STUB_SCRIPT` that fakes `run`/`save` side effects; assert on `$DOCKER_LOG` lines and `$output` substrings |
| Tests: errexit-sensitive | `tests/build_selftest.bats:13-27` | `write_driver` generates a real `bash` script that sources build.sh and overrides expensive functions, because `run` disables errexit |
| Tests: no-dist guarantee | `tests/build_package.bats:193` | Assert on absence (`[ ! -e … ]`) in dist/ after a failing path |

## Files to Change
| File | Action | Why |
|---|---|---|
| `build.sh` | UPDATE | Factor `stage_bundle_tree` out of `package_bundle`; factor `verify_stack_responds` out of `run_selftest`; add `run_local`; add `--run-local` to `main`/`usage` |
| `tests/build_run_local.bats` | CREATE | Unit tests for `run_local` and the `--run-local` flag against stubbed docker/curl |
| `tests/build_package.bats` | UPDATE | Add one test that `stage_bundle_tree` alone produces the staged tree (copy + strip + schema + substituted compose) with no tars |
| `tests/test_helper.bash` | UPDATE | Add `stub_curl`/`unstub_curl` (same shape as `stub_docker`) so `verify_stack_responds` is testable |
| `README.md` | UPDATE | One paragraph under "Development": what `--run-local` does, when to use it vs `--selftest` |
| `CLAUDE.md` | UPDATE | Add `./build.sh --run-local` to Commands; note `stage_bundle_tree` is the shared staging step |
| `.claude/prds/local-prepackage-check.prd.md` | UPDATE | Milestone 1 → in-progress, Plan cell → this file |

## Tasks

### Task 1: Extract `stage_bundle_tree` from `package_bundle`
- **Action**: New function `stage_bundle_tree "$root"` containing, verbatim and in order, `package_bundle`'s `mkdir -p "$root/images" "$root/initdb"`, `cp -a`, the `rm -rf .env nginx/certs` (with its comment block), `generate_schema`, and `substitute_compose_images`. `package_bundle` calls it, then continues with `save_images`, `assert_compose_images_saved`, `write_provenance`, `write_manifest`, `tar`. Moving `substitute_compose_images` ahead of `save_images` is safe — nothing in `save_images` reads the compose file.
- **Mirror**: Existing function/comment style; keep the comment about stripping builder-local secrets attached to the `rm -rf`.
- **Validate**: `bats tests/build_package.bats` — all existing tests pass unchanged (they exercise `package_bundle` end to end). Add: `stage_bundle_tree` on a fixture bundle yields `docker-compose.yml` with no `__*_IMAGE_REF__` left, `initdb/001-schema.sql` non-empty, no `.env`, no `nginx/certs`, and `images/` empty.

### Task 2: Extract `verify_stack_responds` from `run_selftest`
- **Action**: New function `verify_stack_responds "$label"` holding the two `curl` probes (login page, `POST /api/tokens` → non-empty `authToken`) with their `die` messages parameterised on `$label` (`Selftest` / `Run-local`). `run_selftest` calls `verify_stack_responds Selftest`.
- **Mirror**: `build.sh:328-336` as-is; only the `log_info`/`die` prefix changes.
- **Validate**: `bats tests/build_selftest.bats` still green (it overrides `run_selftest` wholesale, so it is unaffected). New test in `tests/build_run_local.bats` with `stub_curl`: a stub returning `{"authToken":"abc"}` passes; a stub returning `{}` dies with `could not obtain an authToken`.

### Task 3: Add `run_local`
- **Action**:
  ```
  run_local() {
      (
          local work_dir root
          work_dir="$(mktemp -d "${TMPDIR:-/tmp}/guac-runlocal.XXXXXX")"
          root="$work_dir/guacamole-offline-${GUACAMOLE_TAG}"
          trap '( cd "$root" 2>/dev/null && docker compose down -v ) 2>/dev/null || true; rm -rf "$work_dir"' EXIT
          stage_bundle_tree "$root"
          write_local_env "$root"        # openssl rand + sed on env.template, umask 077
          write_local_tls_cert "$root"   # openssl req into $root/nginx/certs
          log_info "Run-local: bringing the stack up from $root"
          ( cd "$root" && docker compose --env-file .env up -d --wait --wait-timeout 180 ) \
              || die "Run-local: stack did not come up healthy — run: (cd $root && docker compose ps; docker compose logs)"
          verify_stack_responds Run-local
          log_info "Run-local passed: bundle/ brings up a healthy stack"
      )
  }
  ```
  `write_local_env` / `write_local_tls_cert` are two small helpers (≈6 lines each) copied from `install.sh`'s `configure_env`/`generate_tls_cert` minus the idempotency branches — the tree is always fresh. Note in a comment that they intentionally mirror `install.sh` and must stay in sync, same as `compose_image_refs`.
  Cleanup order matters: `down -v` before `rm -rf` (compose needs the file); `2>/dev/null || true` so a failure before `up` doesn't mask the real error.
- **Mirror**: `run_selftest`'s subshell + EXIT trap (`build.sh:319`); `package_bundle`'s `mktemp` naming.
- **Validate**: `tests/build_run_local.bats` with stubbed docker, `verify_stack_responds` overridden to `:` where curl isn't the subject:
  1. calls `compose … up -d --wait` with `-f`/cwd inside a `guac-runlocal.*` dir, and never calls `docker save` — `! grep -q '^save' "$DOCKER_LOG"`.
  2. `.env` exists (mode 600, password substituted, no `__POSTGRES_PASSWORD__`) and `nginx/certs/{fullchain,privkey}.pem` exist at the moment `up` runs — stub script checks the cwd's files and exits 1 if missing.
  3. after success, `compose down -v` was logged and the temp dir is gone.
  4. when `up` fails (stub exits 1), output contains `did not come up healthy`, `down -v` was still logged, temp dir gone, and `dist/` does not exist.
  5. `bundle/` in the repo (or the fixture `BUNDLE_DIR`) has no `.env` or `nginx/certs` afterwards.

### Task 4: Wire `--run-local` into `main` and `usage`
- **Action**: `--run-local) run_local_only=1 ;;`. After `load_versions` and `pull_images`: if set, `run_local` and `return 0` — packaging is skipped entirely. `--run-local` and `--selftest` together → `die "--run-local and --selftest are mutually exclusive"`. Update `usage` text.
- **Mirror**: `main`'s existing `case`; `build_selftest.bats`'s `write_driver` for the flag tests.
- **Validate**: driver-script tests: `--run-local` calls `run_local` and not `package_bundle` (override both to `echo` markers); both flags → non-zero with the mutual-exclusion message; `--help` lists `--run-local`.

### Task 5: Test helper — `stub_curl`
- **Action**: Add `stub_curl`/`unstub_curl` to `tests/test_helper.bash`, structurally identical to `stub_docker` (own bin dir, `CURL_LOG`, optional `CURL_STUB_SCRIPT`). Reuse the same `STUB_BIN_DIR` if already created by `stub_docker` so one `PATH` entry covers both.
- **Mirror**: `tests/test_helper.bash:7-29`.
- **Validate**: `tests/scaffold.bats` gains "stub_curl intercepts curl and logs its arguments".

### Task 6: Docs and PRD bookkeeping
- **Action**: README "Development" paragraph; CLAUDE.md Commands line + one bullet under Architecture about `stage_bundle_tree` being the single staging definition; flip PRD milestone 1 to `in-progress` with the plan path.
- **Validate**: `git diff` review; `bats tests/shellcheck.bats`.

## Validation
```bash
bats tests/*.bats                       # everything, including the new file
bats tests/build_run_local.bats         # the new unit tests alone
shellcheck build.sh bundle/install.sh   # also run by tests/shellcheck.bats
./build.sh --help                       # shows --run-local
# Manual end-to-end (needs Docker, real digests in versions.env, ports 80/443 free):
./build.sh --run-local
docker compose ls                       # nothing left running
ls dist/ 2>/dev/null                    # unchanged — no tarball produced
```

## Risks
| Risk | Likelihood | Mitigation |
|---|---|---|
| `docker compose up --wait` semantics differ from `wait_healthy` (e.g. services without healthchecks) | Low | All four services define healthchecks; `--wait` waits on exactly those. Confirmed available on the local Compose v5.4. |
| `down -v` in the EXIT trap runs before compose ever started and hides the real failure | Low | Trap redirects its own stderr and `\|\| true`s; the `die` message has already been printed by then. Tested (Task 3, case 4). |
| Refactor of `package_bundle` changes packaged output | Low | Existing `build_package.bats` tests assert the packaged tree byte-for-byte on the parts that matter; run before and after. |
| `write_local_env`/`write_local_tls_cert` drift from `install.sh` | Medium | Comment both sides as a mirrored pair (existing `compose_image_refs` precedent). Milestone 2 could add a test that greps both for the same `openssl` invocation. |
| Ports 80/443 already bound by a real local install or a concurrent `--selftest` | Medium | Compose fails fast with a port-binding error surfaced by the `die` message. Alternate-port support deferred. |
| The 60 s metric is dominated by Tomcat/Postgres startup | Medium | Not something this plan controls; measure once and reframe the metric if needed (already flagged in PRD). |

## Acceptance
- [ ] All tasks complete
- [ ] `bats tests/*.bats` passes, including the new `build_run_local.bats`
- [ ] Both scripts shellcheck-clean
- [ ] `./build.sh --run-local` on a machine with real digests brings the stack up, passes both probes, tears down, and leaves `dist/` and `bundle/` untouched
- [ ] Patterns mirrored, not reinvented: no RETURN traps, no new hard dependencies (no jq), `die` messages are actionable
