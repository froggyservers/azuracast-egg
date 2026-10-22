#!/bin/bash
# Prints the line the egg waits for once AzuraCast answers on its web port.
port="${AZURACAST_HTTP_PORT:-8080}"
for _ in $(seq 1 600); do
  if curl -fs -o /dev/null "http://127.0.0.1:$port/api/status"; then
    echo "AzuraCast is ready on port $port"
    exit 0
  fi
  sleep 1
done
echo "AzuraCast did not answer on port $port within 10 minutes"
exit 1
