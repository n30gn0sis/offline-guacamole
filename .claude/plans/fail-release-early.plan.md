# Plan: Fail the Release Early

**Source PRD**: .claude/prds/local-prepackage-check.prd.md
**Selected Milestone**: 2 — Fail the release early
**Complexity**: Small

## Summary
Make every release build run the local pre-package check by default:
`./build.sh` (with or without `--selftest`) calls `run_local` after
`pull_images` and before `package_bundle`, so a broken `bundle/` aborts the
build before any `docker save`/tar work and before a tarball exists in
`dist/`. Add `--no-run-local` as the opt-out. Add a parity test that locks
the deliberately mirrored code between `build.sh` and `install.sh` so the
local run cannot silently drift from what the installer does.

## Decisions
| Question | Decision | Why |
|---|---|---|
| Default-on or opt-in? | Default-on, `--no-run-local` to skip | The PRD milestone is "a release build runs the local check … and stops before the expensive steps". Opt-in would never fire when it matters. |
| With `--selftest`, run both? | Yes: `run_local` → package → `run_selftest` | Two stack boots, but they prove different things (bundle content vs. the shipped tarball + `install.sh`). The first is cheap relative to save/tar/extract/load. |
| Failure handling | Bare call in `main`, no trap needed | `run_local` is a bare statement so its subshell keeps errexit; `die` inside it exits `main` before `package_bundle`. No tarball exists yet, so nothing to rename — unlike the selftest's `mark_unverified_on_exit`. |
| `--run-local --no-run-local` | `die` as mutually exclusive | Same shape as the existing `--run-local`/`--selftest` guard. |
| Parity test scope | Exact-string greps on both scripts | The mirrored pairs are `openssl rand -base64 24`, `openssl req -x509 -nodes -newkey rsa:2048`, the `s\|__POSTGRES_PASSWORD__\|` sed, and the `compose_image_refs` awk one-liner. A grep that fails when either side changes alone is enough; no need to execute anything. |

## Patterns to Mirror
| Category | Source | Pattern |
|---|---|---|
| Flag parsing | `build.sh:472-473` | `--flag) var=1 ;;` in `main`'s `case`; boolean locals default to 0 |
| Mutual exclusion | `build.sh:479-481` | `if [[ a && b ]]; then die "… mutually exclusive: <why>"` before any work |
| Bare call keeps errexit | `build.sh` `run_selftest "$tarball"` in `main` | Call `run_local` as a bare statement, never inside `if !`/`\|\|`/`&&` |
| Flag tests | `tests/build_run_local.bats` `write_driver` | Driver script sources build.sh, overrides expensive functions with `MARK` echoes to stderr; assert on presence, absence, and order of markers |
| Static config tests | `tests/bundle_config.bats` | Plain `grep -q` / `grep -c` assertions against repo files, no stubs |
| Usage text | `build.sh` `usage()` | One aligned line per flag |

## Files to Change
| File | Action | Why |
|---|---|---|
| `build.sh` | UPDATE | `--no-run-local` flag; call `run_local` before `package_bundle` unless skipped; `usage`; mutual-exclusion guard |
| `tests/build_run_local.bats` | UPDATE | Driver tests for default-on, opt-out, abort-before-package, ordering with `--selftest`, and the new exclusion |
| `tests/build_install_parity.bats` | CREATE | Locks the mirrored `openssl`/`sed`/`awk` lines across `build.sh` and `bundle/install.sh` |
| `README.md` | UPDATE | Step 2 of "Building a release": the build now brings the stack up locally first; mention `--no-run-local` |
| `CLAUDE.md` | UPDATE | Commands block: default build runs the local check; `--no-run-local`; new parity test |
| `.claude/prds/local-prepackage-check.prd.md` | UPDATE | Milestone 2 → in-progress, Plan cell → this file |

## Tasks

### Task 1: `--no-run-local` and the default call in `main`
- **Action**: Add `skip_run_local=0` and `--no-run-local) skip_run_local=1 ;;`. Guard: `--run-local` + `--no-run-local` → `die "--run-local and --no-run-local are mutually exclusive."`. After `pull_images` and the existing `--run-local`-only early return, add:
  ```
  if [[ "$skip_run_local" -eq 0 ]]; then
      # Bare call so run_local's subshell keeps errexit (see the comment on
      # mark_unverified_on_exit for why a conditional would break that).
      # A failure here exits before package_bundle, so no tarball is ever
      # written — nothing to rename, unlike the post-package selftest.
      run_local
  else
      log_info "Skipping the local pre-package check (--no-run-local)"
  fi
  ```
  Update `usage`: `[--selftest] [--run-local | --no-run-local]`, and one line for `--no-run-local`.
- **Mirror**: `build.sh:472-481`, the bare `run_selftest` call.
- **Validate**: `bats tests/build_run_local.bats` — new driver tests:
  1. plain build: `MARK run_local` appears **before** `MARK package_bundle`.
  2. `--no-run-local`: `MARK package_bundle` present, `MARK run_local` absent, "Skipping" logged.
  3. `run_local` overridden to `die "simulated local failure"`: exit non-zero, message present, `MARK package_bundle` absent.
  4. `--selftest`: markers in order `run_local`, `package_bundle`, `run_selftest`.
  5. `--run-local --no-run-local`: non-zero, "mutually exclusive", no markers.
  6. existing "`--run-local` never packages" and "plain build never runs the local check" — the second test's expectation flips; rewrite it as test 1 above.
  Also `bash build.sh --help` mentions `--no-run-local`.

### Task 2: Parity test
- **Action**: `tests/build_install_parity.bats`, four tests, each `grep -qF` for the exact line fragment in both `build.sh` and `bundle/install.sh` and asserting equal counts where relevant:
  - `openssl rand -base64 24`
  - `openssl req -x509 -nodes -newkey rsa:2048`
  - `sed "s|__POSTGRES_PASSWORD__|${pg_password}|"`
  - `awk '$1 == "image:" { print $2 }'`
  Header comment explains these are the deliberately duplicated lines and that a failure means "you changed one side; change the other, or decide they should differ and update this test".
- **Mirror**: `tests/bundle_config.bats` static-grep style; the `compose_image_refs` comment in both scripts.
- **Validate**: `bats tests/build_install_parity.bats` green; then temporarily change `-base64 24` to `-base64 32` in one script and confirm the test fails; revert.

### Task 3: Docs and PRD bookkeeping
- **Action**: README step 2: "Run `./build.sh --selftest`. This pulls the pinned images by digest, brings the stack up locally from `bundle/` as a fast sanity check (`--no-run-local` skips it), then …". CLAUDE.md Commands: annotate `./build.sh` with "runs the local check first; `--no-run-local` to skip", and add `tests/build_install_parity.bats` to the invariants bullet about mirrored pairs. PRD: milestone 2 → in-progress with this plan path.
- **Validate**: `git diff` review.

## Validation
```bash
bats tests/*.bats
bats tests/build_run_local.bats tests/build_install_parity.bats
shellcheck build.sh bundle/install.sh
bash build.sh --help
# Manual, on a Docker host with real digests:
./build.sh                  # local check runs first, then packages
./build.sh --no-run-local   # packages without the local check
```

## Risks
| Risk | Likelihood | Mitigation |
|---|---|---|
| Default-on check surprises a build machine where ports 80/443 are busy | Medium | `--no-run-local` is documented in README step 2 and `--help`; the `die` message already says ports must be free |
| Two stack boots under `--selftest` feel slow | Low | Each boot is well under the save/tar/extract/load cost it precedes; measure once and reconsider if it isn't |
| Parity test is brittle to harmless reformatting | Low | It greps short exact fragments, not whole lines; reformatting either side without changing the fragment still passes |
| Milestone 1's manual acceptance is still unchecked (Docker unreachable from the dev shell so far) | — | Run `./build.sh --run-local` for real before relying on this milestone; a bug there becomes a blocker for every build once the check is default-on |

## Acceptance
- [ ] All tasks complete
- [ ] `bats tests/*.bats` green (except the pre-existing Docker-dependent `nginx -t` test where no daemon is reachable)
- [ ] Both scripts shellcheck-clean
- [ ] Parity test proven to fail on a one-sided change, then passes
- [ ] Manual: `./build.sh` on a real Docker host runs the local check before packaging; `--no-run-local` skips it
