#!/bin/bash
# Prepares a boot as whatever UID/GID the container runs as, then hands over to AzuraCast's
# own my_init (its init scripts, then supervisord). See NOTES.md.
set -euo pipefail

RT=/tmp/egg            # per boot
HC=/home/container     # persistent

# Writes passwd/group so the name "azuracast" is the given UID/GID. Any other entry with the
# same ID is dropped, or name lookups for our UID could return that one instead.
write_identity() {
  local uid="$1" gid="$2"
  mkdir -p "$RT/etc"
  awk -F: -v OFS=: -v u="$uid" -v g="$gid" -v h="$HC" '
    $1 == "azuracast" { $3 = u; $4 = g; $6 = h; print; next }
    $3 == u { next }
    { print }' /egg/orig/passwd > "$RT/etc/passwd"
  awk -F: -v OFS=: -v g="$gid" '
    $1 == "azuracast" { $3 = g; print; next }
    $3 == g { next }
    { print }' /egg/orig/group > "$RT/etc/group"
}

# Stage 1, as PID 1: become tini (PID 1 stays, so /proc/1 belongs to the runtime user, which
# services log to). Started as root (plain Docker, or a node configured that way), first drop
# to AzuraCast's usual UID and hand it the data.
if [ "${1:-}" != --under-tini ]; then
  if [ "$(id -u)" = 0 ]; then
    uid="${AZURACAST_PUID:-1000}" gid="${AZURACAST_PGID:-1000}"
    write_identity "$uid" "$gid"
    mkdir -p "$HC"
    chown -R "$uid:$gid" "$RT" "$HC"
    # Services reopen PID 1's stdout/stderr (/proc/1/fd/N); Docker made those (TTY or pipes)
    # root's, so hand them over too.
    chown "$uid:$gid" /proc/self/fd/0 /proc/self/fd/1 /proc/self/fd/2 2>/dev/null || true
    exec gosu azuracast /usr/bin/tini -- "$0" --under-tini
  fi
  exec /usr/bin/tini -- "$0" --under-tini
fi

write_identity "$(id -u)" "$(id -g)"
export HOME="$HC" USER=azuracast

# Environment: upstream defaults, overridden by what Wings passes, but PATH stays upstream's.
mkdir -p "$RT"
export -p > "$RT/given.env"
set +u
# shellcheck disable=SC1091
source /etc/upstream.env
upstream_path="$PATH"
# shellcheck disable=SC1091
source "$RT/given.env"
set -u
export PATH="$upstream_path"
export ENABLE_WEB_UPDATER=false
# Everything started from here has the full environment; see exec-env.sh.
export EGG_ENV_LOADED=1

# Secrets: generated once per server, never shared between servers.
mkdir -p "$HC/.secrets"
chmod 700 "$HC/.secrets"
secret() {
  local f="$HC/.secrets/$1"
  [ -s "$f" ] || (umask 077 && openssl rand -hex 24 > "$f")
  cat "$f"
}
MYSQL_PASSWORD="$(secret mysql_password)"
MARIADB_ROOT_PASSWORD="$(secret mysql_root_password)"
export MYSQL_PASSWORD MARIADB_ROOT_PASSWORD

# Ports. The web UI, streams (/listen/...) and the web DJ all go through SERVER_PORT, so one
# allocation is enough. HTTPS is optional and loopback-only unless an allocation is given.
export AZURACAST_HTTP_PORT="${SERVER_PORT:-8080}"
export AZURACAST_HTTPS_PORT="${AZURACAST_HTTPS_PORT:-127.0.0.1:61443}"
export AZURACAST_SFTP_PORT="${AZURACAST_SFTP_PORT:-2022}"
# Stations get blocks of 10 ports from this range; keep it clear of the web port.
if [ -z "${AUTO_ASSIGN_PORT_MIN:-}" ]; then
  if [ "$AZURACAST_HTTP_PORT" -ge 8000 ] && [ "$AZURACAST_HTTP_PORT" -le 8509 ]; then
    export AUTO_ASSIGN_PORT_MIN=18000 AUTO_ASSIGN_PORT_MAX=18499
  else
    export AUTO_ASSIGN_PORT_MIN=8000 AUTO_ASSIGN_PORT_MAX=8499
  fi
fi

# Per-boot runtime files (the image's paths are symlinks into $RT).
mkdir -p "$RT"/run/mysqld "$RT"/run/redis "$RT"/nginx/sites-available "$RT"/nginx/sites-enabled \
  "$RT"/mysql-conf.d "$RT"/php "$RT"/valkey "$RT"/log/mysql "$RT"/log/valkey "$RT"/log/liquidsoap
rm -rf "$RT/sftpgo" "$RT"/nginx/sites-enabled/*
cp -R --preserve=mode,timestamps /egg/orig/sftpgo "$RT/sftpgo"

# Persistent data.
mkdir -p "$HC"/mysql "$HC"/stations "$HC"/backups "$HC"/storage \
  "$HC"/.cache/www_tmp "$HC"/.cache/php_uploads "$HC"/.cache/php_tmp "$HC"/.cache/nginx_lib
cp -R -n --preserve=mode,timestamps /egg/orig/storage/. "$HC/storage/"
mkdir -p "$HC/.cache/liquidsoap"
cp -R -n --preserve=mode,timestamps /egg/orig/liquidsoap-cache/. "$HC/.cache/liquidsoap/"

# nginx and SFTPGo write large temp files to fixed /tmp paths; keep them on disk.
for d in nginx_client nginx_fastcgi nginx_cache sftpgo_temp; do
  mkdir -p "$HC/.cache/$d"
  rm -rf "/tmp/$d"
  ln -s "$HC/.cache/$d" "/tmp/$d"
done

echo "[egg] Running as azuracast ($(id -u):$(id -g)), web on port $AZURACAST_HTTP_PORT"
exec /usr/local/bin/my_init --no-main-command
