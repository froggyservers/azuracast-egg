#!/bin/bash
# Runs the image the way Wings does: arbitrary non-root UID, /tmp as a small tmpfs, Wings'
# dropped capabilities, no-new-privileges, a PID limit, a TTY and a volume at /home/container.
# Usage: tests/run-like-wings.sh [image] [uid:gid] [host port]
#   KEEP_DATA=1 reuses the data volume from the previous run (restart test).
#   CPUS=2 sets a CPU limit, as Wings does for servers with one.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows would rewrite /home/container

IMAGE="${1:-azuracast-egg:dev}"
USER_ID="${2:-988:988}"
HOST_PORT="${3:-18080}"
NAME=az-test
VOLUME=az-test-data

docker rm -f "$NAME" >/dev/null 2>&1 || true
if [ -z "${KEEP_DATA:-}" ]; then
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
fi
docker volume create "$VOLUME" >/dev/null
# Wings creates the server directory owned by its container user.
docker run --rm -v "$VOLUME":/home/container --entrypoint chown "$IMAGE" "$USER_ID" /home/container

docker run -d --name "$NAME" -t \
  --user "$USER_ID" \
  -e SERVER_PORT=8080 -e SERVER_IP=0.0.0.0 -e SERVER_MEMORY=2048 -e TZ=UTC \
  -p "$HOST_PORT":8080 \
  -v "$VOLUME":/home/container \
  --tmpfs /tmp:rw,exec,nosuid,size=100m \
  --security-opt no-new-privileges \
  --cap-drop setpcap --cap-drop mknod --cap-drop audit_write --cap-drop net_raw \
  --cap-drop dac_override --cap-drop fowner --cap-drop fsetid --cap-drop net_bind_service \
  --cap-drop sys_chroot --cap-drop setfcap \
  --pids-limit 512 --memory 2g ${CPUS:+--cpus "$CPUS"} \
  "$IMAGE" >/dev/null

# Wait for the egg's ready line (what Pelican waits for), a failure, or the container exiting.
for _ in $(seq 1 120); do
  logs="$(docker logs "$NAME" 2>&1 || true)"
  if grep -q "AzuraCast is ready" <<<"$logs"; then
    echo "READY: http://localhost:$HOST_PORT"
    exit 0
  fi
  if grep -q "did not answer" <<<"$logs" || [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
    break
  fi
  sleep 5
done
echo "NOT READY"
docker logs "$NAME" 2>&1 | tr -d '\r' | tail -40
docker exec "$NAME" supervisorctl status 2>/dev/null || true
exit 1
