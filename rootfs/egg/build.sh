#!/bin/bash
# Runs once at image build, as root, on the flattened upstream filesystem.
set -euo pipefail

RT=/tmp/egg            # per-boot files (Wings mounts /tmp as tmpfs)
HC=/home/container     # Pelican's persistent mount on every node

# Replace a path with a symlink, failing the build if upstream moved it.
relink() {
  local path="$1" target="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    echo "build: expected $path in the upstream image" >&2
    exit 1
  fi
  rm -rf "$path"
  ln -s "$target" "$path"
}

# No way to become root once the passwd file is writable by the runtime user.
find / -xdev -type f -perm /6000 -exec chmod ug-s {} +

# File capabilities (e.g. sftpgo's cap_net_bind_service): Wings drops those capabilities, and
# the kernel then refuses to exec such a binary at all (EPERM). Nothing here needs them.
python3 - <<'PY'
import os
for root, dirs, files in os.walk("/"):
    if root == "/" :
        dirs[:] = [d for d in dirs if d not in ("proc", "sys", "dev")]
    for name in files:
        path = os.path.join(root, name)
        try:
            os.removexattr(path, "security.capability", follow_symlinks=False)
            print("build: removed file capabilities from", path)
        except OSError:
            pass
PY

# Originals the entrypoint starts from on every boot.
mkdir -p /egg/orig
cp -a /etc/passwd /etc/group /egg/orig/
cp -a /var/azuracast/sftpgo /egg/orig/sftpgo
cp -a /var/azuracast/storage /egg/orig/storage

# Identity: rewritten per boot to the UID/GID Wings runs us as.
relink /etc/passwd "$RT/etc/passwd"
relink /etc/group "$RT/etc/group"

# Runtime state and rendered configs: per boot, owned by the runtime user.
relink /run "$RT/run"
relink /etc/nginx/nginx.conf "$RT/nginx/nginx.conf"
relink /etc/nginx/sites-available "$RT/nginx/sites-available"
relink /etc/nginx/sites-enabled "$RT/nginx/sites-enabled"
relink /etc/mysql/conf.d "$RT/mysql-conf.d"
relink /usr/local/etc/php-fpm.conf "$RT/php/php-fpm.conf"
# Written at boot (not present in the image).
ln -sfn "$RT/container.env" /container.env
ln -sfn "$RT/php/php.ini" /usr/local/etc/php/php.ini
ln -sfn "$RT/centrifugo.toml" /var/azuracast/centrifugo/config.toml
relink /var/azuracast/sftpgo "$RT/sftpgo"

# Persistent data.
relink /var/lib/mysql "$HC/mysql"
relink /var/azuracast/stations "$HC/stations"
relink /var/azuracast/backups "$HC/backups"
relink /var/azuracast/storage "$HC/storage"
relink /var/azuracast/www_tmp "$HC/.cache/www_tmp"

# Service-owned paths the services write to (they all run as the runtime user now).
cp -a /var/cache/liquidsoap /egg/orig/liquidsoap-cache
relink /var/cache/liquidsoap "$HC/.cache/liquidsoap"
relink /var/log/mysql "$RT/log/mysql"
relink /var/log/valkey "$RT/log/valkey"
relink /var/log/liquidsoap "$RT/log/liquidsoap"
relink /var/lib/valkey "$RT/valkey"
relink /var/lib/nginx "$HC/.cache/nginx_lib"

# PHP-FPM would chown its sockets to group www-data, which the runtime user isn't in. Without
# listen.owner/group the sockets belong to the runtime user, which nginx also runs as.
sed -i -E '/^\s*listen\.(owner|group)\s*=/d' /usr/local/etc/php-fpm.conf.tmpl
if grep -qE '^\s*listen\.(owner|group)\s*=' /usr/local/etc/php-fpm.conf.tmpl; then
  echo "build: php-fpm listen.owner/group is left" >&2
  exit 1
fi

# Everything else the image's own users (azuracast, mysql, valkey, ...) own is only read at
# runtime: make it readable by the runtime user, whatever its UID.
chmod 755 /var/azuracast
find / -xdev ! -uid 0 ! -type l -exec chmod o+rX {} +

# supervisord runs as the runtime user, so it can't switch users. The station programs
# AzuraCast generates keep their user=azuracast, which is a no-op for that same user.
sed -i -E '/^\s*user\s*=/d' /etc/supervisor/supervisord.conf /etc/supervisor/*.conf.d/*.conf
if grep -rqE '^\s*user\s*=' /etc/supervisor; then
  echo "build: a supervisor user= line is left" >&2
  exit 1
fi

# Pelican puts every server on a node on one shared Docker network, so internal services must
# listen on loopback only (upstream relies on its compose network being private). Centrifugo's
# API and admin are unauthenticated, Valkey has no password.
sed -i -E 's/^bind 0\.0\.0\.0$/bind 127.0.0.1/' /etc/valkey/valkey.conf
grep -qx 'bind 127.0.0.1' /etc/valkey/valkey.conf || { echo "build: valkey bind not set" >&2; exit 1; }
printf '[mariadbd]\nbind-address = 127.0.0.1\n' > /etc/mysql/mariadb.conf.d/99-egg-loopback.cnf
sed -i -E 's/^\[http_server\]$/[http_server]\naddress = "127.0.0.1"\ninternal_address = "127.0.0.1"/' \
  /var/azuracast/centrifugo/config.toml.tmpl
grep -q '^internal_address = "127.0.0.1"' /var/azuracast/centrifugo/config.toml.tmpl \
  || { echo "build: centrifugo bind not set" >&2; exit 1; }

# nginx's "auto" means one worker per host core, whatever the server's CPU limit; let the
# entrypoint size it.
sed -i -E 's/^worker_processes auto;$/worker_processes {{ default .Env.NGINX_WORKER_PROCESSES "auto" }};/' \
  /etc/nginx/nginx.conf.tmpl
grep -q 'NGINX_WORKER_PROCESSES' /etc/nginx/nginx.conf.tmpl \
  || { echo "build: nginx worker_processes not templated" >&2; exit 1; }

# usermod needs root; the entrypoint does this instead.
rm /etc/my_init.d/00_setup_user.sh

# Large temp files on disk, not the small /tmp tmpfs.
cat > /usr/local/etc/php/conf.d/zz-egg.ini <<'INI'
upload_tmp_dir = /home/container/.cache/php_uploads
sys_temp_dir = /home/container/.cache/php_tmp
INI

chmod +x /egg/entrypoint.sh /egg/ready.sh
