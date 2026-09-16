# Local Pre-Package Stack Check

## Problem
The only way to prove the contents of `bundle/` actually bring up a healthy
Guacamole stack is `build.sh --selftest`, which runs *after* images are
pulled, saved, and tarred. Anyone editing the compose file, nginx config, env
template, or installer pays a full build cycle to learn a one-line change is
broken, and there is no supported command to run the working-tree bundle in
place at all. Left unsolved, iteration on the install side stays slow and
every bundle edit is effectively tested only at release time.

## Evidence
- Assumption — needs validation via timing a full `build.sh --selftest` cycle
  against a stack-only bring-up on the same machine, and via counting how
  many recent `--selftest` failures were attributable to `bundle/` content
  rather than packaging. (User reports no concrete incident; motivation is
  hygiene, not a forcing event.)

## Users
- **Primary**: the developer editing files under `bundle/` who wants to know
  in seconds, not a build cycle, whether the stack still comes up.
- **Also**: the person cutting a release who wants the cheap check to fail
  first, before the expensive pull/save/tar steps run.
- **Not for**: operators on the disconnected target — they run the shipped
  `install.sh`, and this check never ships in the tarball.

## Hypothesis
We believe **a local run-and-verify of the working-tree bundle, executed
before packaging** will **catch broken bundle content early and make
install-side iteration fast** for **whoever edits `bundle/` or cuts a
release**.
We'll know we're right when **a broken compose/nginx/env edit is reported
well under a minute (excluding image pull time), and `--selftest` stops
failing for reasons the pre-check would have caught**.

## Success Metrics
| Metric | Target | How measured |
|---|---|---|
| Time from invoking the check to a pass/fail verdict on a bundle-content bug | < 60 s, images already local | Stopwatch on a deliberately broken compose edit, before/after |
| `--selftest` failures attributable to `bundle/` content (not packaging) | 0 after adoption | Classify each `--selftest` failure by root cause going forward |
| Check reaches the same verification bar as `--selftest` | Healthchecks pass + HTTPS login page + `guacadmin` API login succeeds | Manual run; parity list against `run_selftest` |

## Scope
**MVP** — A local command that brings the working-tree stack up, waits for
all services to report healthy, confirms the login page answers over HTTPS,
confirms an API login as `guacadmin` succeeds (proving the schema
initialized), then tears everything down including the database volume. The
verification bar is intentionally identical to the existing post-package
selftest.

**Out of scope**
- Testing real RDP/VNC/SSH connections through guacd — this proves the stack
  boots and authenticates, not that remote-desktop sessions work.
- Replacing `build.sh --selftest` — the post-package selftest remains the
  release gate; this check sits in front of it, not instead of it
  (confirmed in framing: "distinct from the existing post-packaging
  --selftest").

## Delivery Milestones
<!-- Business outcomes, not engineering tasks. /plan turns each into a plan. -->
<!-- Status: pending | in-progress | complete -->

| # | Milestone | Outcome | Status | Plan |
|---|---|---|---|---|
| 1 | Run the working-tree bundle locally | A single command brings `bundle/` up, verifies healthy + HTTPS + API login, and tears down cleanly, without producing a tarball | in-progress | .claude/plans/local-prepackage-check.plan.md |
| 2 | Fail the release early | A release build runs the local check before pulling/saving/packaging, and stops before the expensive steps if it fails | pending | — |

## Open Questions
- [ ] Image resolution: the working-tree `docker-compose.yml` carries
      `__*_IMAGE_REF__` placeholders and the stack runs with
      `pull_policy: never`. Should the check require images to already be
      present locally (from a prior `docker pull`), pull them itself from
      `versions.env`, or accept an explicit override?
- [ ] Port conflicts: the stack binds host ports 80/443. Should the check use
      alternate ports so it can coexist with a real local install or a
      concurrent `--selftest`, or is exclusive use of 80/443 acceptable?
- [ ] Reuse vs. bypass `install.sh`: running the real installer in place
      also exercises it, but writes `bundle/.env` and `bundle/nginx/certs/`
      into the working tree (gitignored, and already stripped at package
      time). Is that side effect acceptable, or should the check avoid it?
- [ ] Should the check be part of `bats tests/*.bats`? Today the suite needs
      no Docker; this check needs a real daemon. TBD — user did not mark
      this out of scope.
- [ ] Docker-only, or also Podman? TBD — the rest of the project is
      Docker + Compose v2 only; user did not mark this out of scope.

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Check passes locally but the packaged bundle still fails (drift between working-tree run and tarball contents) | Medium | Medium | Keep `--selftest` as the release gate; treat this check as a fast pre-filter, never a substitute |
| Leftover containers/volumes/ports after a failed run block the next run or a real install | Medium | Medium | Teardown must run on every exit path, matching the existing selftest's cleanup discipline |
| Local secrets/certs generated by the check leak into a shipped bundle | Low | High | Already mitigated: packaging strips `.env` and `nginx/certs/`; the check must not introduce new generated files outside that allow-list |
| The "under a minute" target is dominated by Postgres/Tomcat startup rather than anything the check controls | Medium | Low | Measure; if startup dominates, reframe the metric as "no pull/save/tar cost", not absolute seconds |

---
*Status: DRAFT — requirements only. Implementation planning pending via /plan.*
