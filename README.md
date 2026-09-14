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
2. Run `./build.sh --selftest`. This pulls the pinned images by digest,
   re-tags each one under its plain `repo:tag`, generates the Postgres schema
   from the real webapp image, substitutes the concrete image references into
   the bundle's `docker-compose.yml`, and packages everything into
   `dist/guacamole-offline-<version>-<date>.tar.gz`. It then unpacks that
   tarball and proves it installs and comes up healthy. A tarball that fails
   the selftest is renamed to `...tar.gz.FAILED` so it can never be mistaken
   for a valid release — only a plain `.tar.gz` in `dist/` is shippable.
3. Copy that tarball to the disconnected target by whatever transfer process
   your environment uses (removable media, a one-way diode, etc). Record the
   tarball's own SHA-256 in your transfer paperwork — see "Security notes" in
   `bundle/README.md` for why the in-bundle manifest alone is not enough.

`versions.env` is the single source of truth for image references.
`bundle/docker-compose.yml` carries `__<COMPONENT>_IMAGE_REF__` placeholders
that `build.sh` substitutes at package time, and the build fails if any
placeholder is left over or if the compose file asks for an image that was
not saved into the bundle. Do not hardcode image references in the compose
file.

## Installing on the disconnected target (needs Docker, Compose v2, openssl)

```bash
tar -xzf guacamole-offline-<version>-<date>.tar.gz
cd guacamole-offline-<version>
./install.sh
```

`install.sh` verifies the bundle's integrity (both that every listed file
matches its checksum and that no unlisted file has been added), loads the
images and confirms every image the compose file needs now resolves locally,
generates a random database password and a self-signed TLS certificate
(unless you've already placed your own `fullchain.pem`/`privkey.pem` in
`nginx/certs/` beforehand), brings the stack up, and waits for it to report
healthy. It is safe to re-run — an existing `.env` or certificate is left
untouched.

`provenance.txt` inside the bundle records the repo, tag and digest of every
image it ships, plus the build timestamp and git revision.

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
