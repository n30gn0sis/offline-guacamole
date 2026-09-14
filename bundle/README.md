# Guacamole — offline install

## Install

```bash
./install.sh
```

Requires Docker Engine, Docker Compose v2, and `openssl` already installed on
this host. No internet access is used or required — the compose file sets
`pull_policy: never`, so the stack will never reach out to a registry.

## What this does

1. Preflight: Docker, Compose v2 and `openssl` are present, ports 80/443 are
   free (skipped with a notice if `ss` is not installed), and at least 2 GB
   is free under the Docker data root.
2. Verifies every file in this bundle against `manifest.sha256`, and refuses
   to proceed if the bundle contains any file the manifest does not list.
3. Loads the four bundled container images into the local Docker daemon, then
   confirms every image `docker-compose.yml` asks for now resolves locally.
4. Generates `.env` (random database password) and a self-signed TLS
   certificate, unless they already exist — safe to re-run.
5. Starts Postgres, guacd, the Guacamole webapp, and nginx, and waits for
   all four to report healthy.

## What is in this bundle

`provenance.txt` records exactly what this bundle contains — each image's
repository, tag and sha256 digest, the version, the build timestamp (UTC),
and the git revision `build.sh` was run from. Read it to answer "what did I
just install?" without any registry access.

## Security notes

`manifest.sha256` is an **integrity** check, not an **authenticity** control.
It reliably detects accidental corruption and transfer damage, and it detects
files added to the bundle after it was built. It does *not* protect against a
party with write access to the bundle who tampers with the files and
regenerates the manifest to match — the manifest travels inside the same
tarball as the files it covers, so both can be rewritten together.

Establish authenticity out-of-band for a real deployment: publish the
tarball's own SHA-256 through your transfer paperwork/process, separately
from anything inside the bundle, and check it on arrival before extracting.

`.env` (mode 600) holds the generated database password, and
`nginx/certs/privkey.pem` (mode 600) holds the TLS private key. Neither is
covered by `manifest.sha256` — both are created on this host at install time.

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
