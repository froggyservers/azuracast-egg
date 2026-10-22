# Design notes

Goal: one image and one egg that work on **any** Pelican node, with no per-node values baked in.
Every choice below lists the options considered and why one was picked.

Based on `ghcr.io/azuracast/azuracast:stable` built 2026-10-21 17:47 UTC (AzuraCast 0.23.9,
Debian 13, PHP 8.5.12, ~3 GB).

## How the official image starts

`tini -- /usr/local/bin/my_init --no-main-command`, as **root**:

1. `my_init` dumps the environment to `/container.env`, then runs every `/etc/my_init.d/*.sh`.
2. It `exec`s `supervisord -c /etc/supervisor/supervisord-full.conf`, which includes
   `minimal.conf.d/*` (mariadb, valkey), `full.conf.d/*` and every station's
   `/var/azuracast/stations/*/config/supervisord.conf`.
3. The `startup` program (`app_startup`) waits for redis and the DB, runs
   `azuracast_cli azuracast:setup --init` (also runs DB migrations), then `supervisorctl start`
   php-fpm, centrifugo, nginx and finally `all`.

| init script | does | under Pelican |
|---|---|---|
| 00_disable_mariadb / redis | removes a supervisor conf when the host isn't localhost | keep (we always run both locally) |
| 00_setup_user | `usermod`/`groupmod` azuracast to PUID/PGID | replaced, see "Identity" |
| 01_self_signed_ssl | self-signed cert in `storage/acme` | works once the dir is ours |
| 02_install_extra_packages | `apt-get install` on boot | drop |
| 03_persist_dir | mkdir + chown storage dirs | works (chown is a no-op on own files) |
| 04/05/06 *_conf | render templates with `dockerize` into `/etc/mysql`, `/etc/nginx`, `/usr/local/etc/php`, `/var/azuracast/centrifugo` | those files must be writable, see "Writable paths" |
| 05_setup_db | MariaDB init/upgrade; `gosu mysql` only when uid is 0 | works |
| 07_sftpgo_conf | ssh host keys + port env | works |
| 08_plugin_mode | `gosu azuracast composer update` | drop (plugins off) |
| 10_clear_temp | empties `www_tmp` | works |

## Identity: the runtime UID is unknown until Wings starts the container

AzuraCast checks its user **by name**: `azuracast_cli` and `app_startup` compare `whoami` with
`azuracast` and otherwise `gosu`; supervisor programs, including the station programs PHP
generates (`backend/src/Radio/Configuration.php`, hardcoded `'user' => 'azuracast'`), say
`user=azuracast`. A non-root supervisord accepts `user=` only when it names the user it already
runs as. Wings runs the container as its configured `system.user` UID/GID, which differs between
installs (Pterodactyl used 988; Pelican and custom setups vary).

| option | verdict |
|---|---|
| Bake the UID/GID in at build time | rejected: works only on nodes with that UID |
| Patch the scripts and the PHP generator to drop `gosu` / `user=` | rejected: patches app code, breaks on upstream changes |
| `nss_wrapper` (LD_PRELOAD a fake passwd file in /tmp) | fallback: no writable /etc/passwd, but LD_PRELOAD must reach every process and static Go binaries (centrifugo, sftpgo, supercronic) ignore it |
| **Writable `/etc/passwd` + `/etc/group`; entrypoint rewrites the `azuracast` entry to `id -u`/`id -g` on every start** | **chosen**: works with any UID, no app patches |

Safety for the chosen option: a writable passwd file lets the user set an empty root password,
so the build strips every setuid/setgid bit (`find / -xdev -perm /6000 -exec chmod ug-s`); with
no setuid binaries there is no way to become root. Supervisor confs we own lose `user=mysql`,
`user=valkey` and `user=root`; everything runs as the one runtime user, named `azuracast`.

To verify on a test server: supervisord accepts `user=azuracast` when it runs as that same user.

## Inherited volumes

The image declares `VOLUME`s for `/var/azuracast/{backups,stations,storage/*}` and
`/var/lib/mysql`. Docker creates an anonymous volume for each at container creation, so data
would never reach `/home/container` (missed by Pelican backups, disk limits and reinstalls,
and the volumes pile up on the node).

| option | verdict |
|---|---|
| Child image `FROM` upstream | impossible: a child can't remove inherited `VOLUME`s |
| Fork AzuraCast's own Dockerfile without the `VOLUME` lines | rejected: rebuilding everything from source, diverges from upstream |
| Keep the volumes, point paths elsewhere by config | rejected: most storage paths are hardcoded; empty anonymous volumes still pile up |
| **Flatten: `FROM scratch` + `COPY --from=upstream / /`, re-declare `ENV`/`WORKDIR`/`ENTRYPOINT`** | **chosen**: exact upstream bits, no volumes; costs one 3 GB layer per rebuild |

Upstream `ENV` to carry over: `PATH` (includes `/var/azuracast/storage/shoutcast2`),
`PHP_INI_DIR`, `TZ`, `LANG`/`LC_*`, `APPLICATION_ENV`, `MYSQL_*`, `ENABLE_REDIS`, `REDIS_*`,
`NGINX_RADIO_PORTS`, `NGINX_WEBDJ_PORTS`, `COMPOSER_PLUGIN_MODE`,
`ADDITIONAL_MEDIA_SYNC_WORKER_COUNT`; `ENABLE_WEB_UPDATER=false` (the image is updated, not the
app in place). The build should read the list from the upstream image, not copy it by hand.

## Data location

Everything persistent lives under `/home/container` (Pelican's fixed mount point on every
node): `/var/lib/mysql`, `/var/azuracast/{stations,backups,storage}` become symlinks into
`/home/container/...`, created at build time, so they work on any node.

## Writable paths

Rendered configs and runtime files sit in image paths owned by UID 1000 or root:
`/etc/nginx` (nginx.conf, sites-*), `/etc/mysql/conf.d`, `/usr/local/etc/php*`,
`/var/azuracast/{centrifugo,sftpgo,www_tmp}`, `/run` (supervisor.sock, supervisord.pid,
mysqld, redis), `/container.env`.

| option | verdict |
|---|---|
| chown to a fixed UID at build | rejected: same problem as baking the UID |
| `chmod a+w` on those paths | possible, but loose and easy to miss one |
| **Symlink each into a per-boot dir the runtime user owns** (`/home/container/.runtime/...` or /tmp, recreated by the entrypoint) | **chosen**: works with any UID; the image's own files stay read-only |

## Ports

Pelican only tells the container its primary allocation (`SERVER_IP`, `SERVER_PORT`); extra
allocations are not exposed as environment variables.

- Web: nginx `listen` comes from `AZURACAST_HTTP_PORT` / `AZURACAST_HTTPS_PORT` -> HTTP on
  `SERVER_PORT`.
- Listeners: every station writes an nginx conf that nginx includes, so streams are served under
  `/listen/...` through the web port, and the web DJ through `NGINX_WEBDJ_PORTS`. A server with
  **one allocation is fully usable**.
- Direct Icecast / desktop DJ software / SFTP need real ports. Option: egg variables for a
  station port range and SFTP port that must match extra allocations (fed into
  `AUTO_ASSIGN_PORT_MIN`/`MAX` and `AZURACAST_SFTP_PORT`); off by default. Better if Froggy's
  site sets them when it adds allocations.

## HTTPS

| option | verdict |
|---|---|
| AzuraCast's built-in ACME | rejected: needs ports 80/443 on the node's IP, which a shared node can't give each server |
| Self-signed on a second allocation | fallback only: browser warnings |
| **TLS terminated in front (Froggy's subdomain proxy), plain HTTP inside** | **chosen** where the host has a proxy; HTTP on the allocation otherwise |

## Secrets

Upstream ships `MYSQL_PASSWORD=azur4c457` for everyone. The entrypoint generates a random one on
first boot into `/home/container`, not an egg variable (changing it after first boot would lock
AzuraCast out of its own database).

## Image distribution and updates

- Wings pulls without credentials unless each node is configured for a registry, so the GHCR
  **package must be public** (the repo can stay private).
- A scheduled GitHub Action compares the upstream `stable` digest daily and rebuilds when it
  changes; servers pick it up on restart. No manual step, nothing node-specific.

## Limits to test

- Wings mounts `/tmp` as a small tmpfs (default 100 MB): move PHP upload temp and anything large
  to `/home/container`.
- Wings' container PID limit (default 512) counts threads: MariaDB + PHP-FPM children +
  Liquidsoap per station. Size PHP-FPM children from the server's memory limit.
- RAM per server with one station.
