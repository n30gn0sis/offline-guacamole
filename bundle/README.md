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
