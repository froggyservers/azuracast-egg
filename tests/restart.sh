#!/bin/bash
# Stops the running test server the way Pelican does (SIGINT, as the egg's "^C" stop), then
# starts the given image on the same data and checks nothing was lost or re-initialised.
# Usage: tests/restart.sh [image]   (after tests/run-like-wings.sh and creating a station)
set -euo pipefail
export MSYS_NO_PATHCONV=1
IMAGE="${1:-azuracast-egg:dev}"
NAME=az-test

secret_before="$(docker exec "$NAME" cat /home/container/.secrets/mysql_password)"
stations_before="$(docker exec "$NAME" azuracast_cli azuracast:radio:restart 2>&1 | grep -c 'OK' || true)"

start=$(date +%s)
docker kill --signal=INT "$NAME" >/dev/null
for _ in $(seq 1 60); do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || break
  sleep 1
done
echo "stopped after $(( $(date +%s) - start ))s, exit code $(docker inspect -f '{{.State.ExitCode}}' "$NAME")"

KEEP_DATA=1 bash "$(dirname "$0")/run-like-wings.sh" "$IMAGE"

secret_after="$(docker exec "$NAME" cat /home/container/.secrets/mysql_password)"
[ "$secret_before" = "$secret_after" ] && echo "DB password kept" || { echo "DB password CHANGED"; exit 1; }
docker logs "$NAME" 2>&1 | grep -q "Initializing database files" && { echo "DB was re-initialised"; exit 1; }
echo "DB not re-initialised"
docker exec "$NAME" azuracast_cli azuracast:radio:restart 2>&1 | grep -q 'OK' && echo "stations restart: OK"
echo "stations before: $stations_before"
