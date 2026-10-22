# AzuraCast egg for Pelican

Runs [AzuraCast](https://www.azuracast.com/) as a single Pelican server.

The image is AzuraCast's official `ghcr.io/azuracast/azuracast:stable` with only the startup
changed: it runs as Pelican's non-root `container` user and keeps all data in `/home/container`.
PHP, Liquidsoap, Icecast and their libraries stay exactly as AzuraCast ships them, so a new
upstream release only needs a rebuild.

## Status

The image boots and streams under Wings-like conditions (`tests/run-like-wings.sh`: UID 988,
tmpfs `/tmp`, Wings' dropped capabilities, `no-new-privileges`, PID limit), and survives a
`^C` stop plus an image update on the same data (`tests/restart.sh`). Not yet: the egg JSON,
the GHCR publish/rebuild workflow, and a test on a real Pelican node.

## Layout

- `Dockerfile`: flattens the official image and runs `rootfs/egg/build.sh` on it.
- `rootfs/egg/entrypoint.sh`: per-boot setup as the runtime UID, then AzuraCast's own `my_init`.
- `rootfs/egg/ready.sh` + `rootfs/etc/supervisor/full.conf.d/egg-ready.conf`: prints
  `AzuraCast is ready on port N` once the web port answers (the egg's startup-done line).
- `NOTES.md`: why each piece works the way it does.

## Local test

```bash
docker build -t azuracast-egg:dev .
bash tests/run-like-wings.sh
bash tests/restart.sh
```
