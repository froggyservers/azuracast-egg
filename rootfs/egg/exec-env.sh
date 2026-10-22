# Sourced by every non-interactive bash (BASH_ENV). Shells started outside the server's process
# tree, e.g. `docker exec ... azuracast_cli`, get the environment the server runs with,
# including its generated database password. The server's own processes already have it.
# Never in the entrypoint itself: a /container.env left from an earlier boot is stale there.
if [ -z "${EGG_ENV_LOADED:-}" ] && [ "$0" != /egg/entrypoint.sh ] && [ -r /container.env ]; then
  # shellcheck disable=SC1091
  source /container.env
fi
