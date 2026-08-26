#!/usr/bin/env bash
# Per-shell proxy safety net. Reads PROXY_ACTIVE/PROXY_HOST/PROXY_PORT LIVE
# from the bind-mounted .env (/etc/ping-linux.env) on every new shell — edit
# .env on the host, open a new shell, done. No `docker compose up`/`down`,
# no rebuild, ever required; this is plain bash, not docker-compose
# interpolation, so PROXY_ACTIVE=true/false is a real comparison here.
#
# Even when PROXY_ACTIVE=true, this only turns the proxy ON for a shell if
# PROXY_HOST:PROXY_PORT actually answers within 1s — so an unreachable
# proxy (VPN off, different network) doesn't silently break every command.
ENV_FILE="/etc/ping-linux.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [ "${PROXY_ACTIVE:-}" = "true" ] && [ -n "${PROXY_HOST:-}" ] \
   && curl -s -m 1 -o /dev/null "http://${PROXY_HOST}:${PROXY_PORT}"; then
  export HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}/"
  export HTTPS_PROXY="$HTTP_PROXY"
  export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
else
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
fi
