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
