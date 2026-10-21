# AzuraCast egg for Pelican

Runs [AzuraCast](https://www.azuracast.com/) as a single Pelican server.

The image is AzuraCast's official `ghcr.io/azuracast/azuracast:stable` with only the startup
changed: it runs as Pelican's non-root `container` user and keeps all data in `/home/container`.
PHP, Liquidsoap, Icecast and their libraries stay exactly as AzuraCast ships them, so a new
upstream release only needs a rebuild.

## Status

Work in progress; not usable yet.

## Plan

1. Inspect how the official image starts and what needs root.
2. Entrypoint and supervisord config that run as `container`, data in `/home/container`.
3. Station streaming ports taken from the server's Pelican allocations.
4. Build and push the image to GHCR; write the egg JSON.
5. Test on one node: create a station, stream, restart, reinstall.
