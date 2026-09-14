# Offline Guacamole Deployment — Design Spec

- **Date:** 2026-09-14
- **Status:** Approved (pending user review of this document)
- **Author:** Stephen, with Claude

## 1. Purpose and scope

A reusable, environment-agnostic offline deployment kit for [Apache
Guacamole](https://guacamole.apache.org/) — a build-side toolchain that
produces a self-contained tarball, and an install-side script that stands up
a working Guacamole stack on a disconnected Docker host with no outbound
network access required at any point.

This is not tied to any specific lab or network; it's a portable bundle that
can be carried to any air-gapped or otherwise disconnected environment
running Docker on an Ubuntu/Debian host.

### Out of scope

- Podman/RHEL support (a possible future variant, not this design)
- LDAP/AD authentication (Postgres-backed local auth only)
- A container runtime installer (the target host is assumed to already have
  Docker + Compose v2)
- Multi-host / HA deployment (single-host only)
- Reverse-proxy integration with an existing external TLS terminator (nginx
  with a self-signed cert is bundled and is the sole exposed surface)

## 2. Architecture

Two halves in one repo: a **build side** that runs once per release on a
connected machine, and an **install side** — the tarball it produces — that
runs on the disconnected target.

### 2.1 Repo layout (build side)

```
offline-guacamole/
├── build.sh                 # connected side: pull → verify → save → package
├── versions.env             # single source of truth: image tags + sha256 digests
├── bundle/                  # static files copied into every bundle
│   ├── install.sh
│   ├── docker-compose.yml
│   ├── env.template
│   ├── nginx/nginx.conf
│   └── README.md
└── dist/                    # output: guacamole-offline-<ver>-<yyyymmdd>.tar.gz
```

### 2.2 Bundle layout (install side, inside the tarball)

```
guacamole-offline-<ver>/
├── images/                  # docker-save tars: guacamole, guacd, postgres, nginx
│   └── manifest.sha256      # checksums of everything in the bundle
├── initdb/001-schema.sql    # generated at build time by the guacamole image itself
├── docker-compose.yml
├── env.template             # becomes .env at install (secrets filled in)
├── nginx/nginx.conf         # + certs/ created at install
├── install.sh
└── README.md
```

### 2.3 Runtime topology

Four containers on one Compose network:

| Service     | Exposed to host? | Role                                    |
|-------------|-------------------|------------------------------------------|
| `nginx`     | Yes — 443 (+80→443 redirect) | Sole published surface; TLS termination |
| `guacamole` | No (internal only) | Tomcat webapp, port 8080 internally      |
| `guacd`     | No (internal only) | Guacamole proxy daemon                   |
| `postgres`  | No (internal only) | User/connection/permission storage       |

Postgres data lives in a named volume. The schema SQL mounts into
`/docker-entrypoint-initdb.d/` so the database initializes itself on first
boot. The schema file is produced at **build time** by running the pinned
webapp image's own `initdb.sh` script — so the schema always matches the
exact webapp version shipped in that bundle; they can never drift apart.

Runtime data flow: browser → nginx (TLS) → guacamole webapp → guacd → target
RDP/VNC/SSH hosts, with the webapp reading users/connections from Postgres.
Nothing in the stack requires outbound internet access at any point.

## 3. Build-side behavior (`build.sh`)

1. Read `versions.env`, which pins each of the four images by **tag and
   digest** (e.g. `guacamole/guacamole:1.6.0@sha256:...`).
2. Pull each image **by digest**. A tag that has been re-pushed upstream
   fails the pull loudly rather than silently changing what ships in the
   bundle.
3. Run the pulled webapp image once with `initdb.sh --postgresql` to capture
   `initdb/001-schema.sql`.
4. `docker save` each image into `images/`.
5. Copy the static `bundle/` files (install.sh, compose file, env template,
   nginx config, README) into the output tree.
6. Write `manifest.sha256` covering every file in the bundle.
7. Assemble the whole tree in a temp directory and `tar`/`gzip` it into
   `dist/guacamole-offline-<ver>-<yyyymmdd>.tar.gz` — moved into place
   atomically only on success, so a failed build never leaves a partial or
   corrupt tarball in `dist/`.

Releasing a new Guacamole version means editing two lines in
`versions.env` (tag + digest) and re-running `build.sh`.

### 3.1 `build.sh --selftest` (release gate)

Unpacks the just-built tarball into a temp dir, runs `install.sh` against it
on the build machine itself, waits for the stack to report healthy, confirms
the login page answers over HTTPS, and does an API login as `guacadmin`
(`POST /api/tokens`) to prove the database schema initialized correctly —
then tears the stack down and removes the volume. A tarball is only
considered a valid release if its own install passes this self-test.

## 4. Install-side behavior (`install.sh`)

Idempotent — safe to re-run against an existing install. Steps, in order:

1. **Preflight:** confirm Docker is present, Compose v2 is present, ports
   443/80 are free, and at least 2 GB of free disk space is available under
   the Docker data root (covers the four loaded images plus initial Postgres
   volume growth). Each failure names what's missing and how to fix it
   (e.g. "Docker Compose v2 not found — install docker-compose-plugin").
2. **Integrity check:** verify every file against `manifest.sha256`; abort
   and name the exact corrupt/mismatched file on any failure (distinguishes
   transfer damage from tampering).
3. **Load images:** `docker load` each tar in `images/`.
4. **Configure secrets (first run only):** create `.env` from
   `env.template`, generating a random Postgres password with `openssl
   rand` and `chmod 600`-ing the file. On a re-run, an existing `.env` is
   left untouched.
5. **TLS cert (first run only):** generate a self-signed certificate into
   `nginx/certs/` unless a cert/key pair is already present there — so a
   real certificate can be dropped in before or after install and will be
   respected.
6. **Bring up the stack:** `docker compose up -d`.
7. **Health wait:** poll each service's healthcheck (`pg_isready` for
   Postgres, a port probe for guacd, an HTTP check for Tomcat, and one for
   nginx) until all report healthy or a timeout is hit.
8. **Report:** print the HTTPS URL, and a loud warning that the default
   `guacadmin` / `guacadmin` account must have its password changed on
   first login.

## 5. Error handling

Both scripts run under `set -euo pipefail` and every failure names the
specific step that failed rather than surfacing raw shell/tool output.

- **Build side:** a digest mismatch on pull or a failed schema-generation
  step aborts the build before anything is written to `dist/`.
- **Install side:** preflight and checksum failures are actionable and
  specific (see §4.1–4.2 above). If the post-`up` health wait times out,
  `install.sh` prints per-service status plus the exact `docker compose
  logs <service>` command to run next — the goal is that a failure on an
  air-gapped box is diagnosable entirely from the script's own output,
  without needing outside help.

## 6. Testing

- **Static analysis:** `shellcheck` on both `build.sh` and `install.sh`.
- **Release gate:** `build.sh --selftest` (§3.1) — no tarball is a valid
  release unless its own install, health-wait, and `guacadmin` API login
  succeed.
- **Target acceptance:** the health-wait step at the end of `install.sh`
  doubles as the acceptance test on the real disconnected target — a
  successful run is itself proof the stack is live and correctly
  initialized.

## 7. Open items / explicit non-decisions

None outstanding — all design questions were resolved during brainstorming
(target: generic Docker/Ubuntu host; Postgres-backed auth; tarball +
install-script bundle format; bundled nginx with self-signed TLS; build
script included and digest-pinned).

Future extensions noted but deliberately deferred (see §1 Out of scope):
Podman/RHEL variant, LDAP/AD auth, external reverse-proxy mode.
