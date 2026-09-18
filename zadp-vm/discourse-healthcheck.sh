#!/usr/bin/env bash
#
# Restart Discourse if it stops answering.
#
# What this covers and what it does not:
#   - GCE automaticRestart reboots the VM on a crash or host failure.
#   - docker.service is enabled at boot and the container is --restart=always,
#     so the app comes back after a reboot or a container exit.
#   - Neither notices a container that is UP but not serving: a wedged unicorn,
#     Postgres out of connections, an OOM that left the process alive. That is
#     what this script is for.
#
# Runs every 5 minutes from discourse-healthcheck.timer.
set -uo pipefail

HOSTNAME_CANON="${DISCOURSE_HOSTNAME_CANON:-community.zyte.com}"
STATE=/var/lib/discourse-healthcheck.fails
THRESHOLD=3          # ~15 minutes of failure before acting
log() { logger -t discourse-health -s "$*"; }

mkdir -p "$(dirname "$STATE")"
fails=$(cat "$STATE" 2>/dev/null || echo 0)

# Ask the app over the loopback, with the canonical Host header so Discourse
# does not answer with a redirect to itself. -k because the cert is for the
# public name, not for 127.0.0.1.
if curl -fsS -k -o /dev/null --max-time 20 \
      -H "Host: ${HOSTNAME_CANON}" "https://127.0.0.1/srv/status"; then
  [ "$fails" -gt 0 ] && log "recovered after $fails consecutive failures"
  echo 0 > "$STATE"
  exit 0
fi

fails=$((fails + 1))
echo "$fails" > "$STATE"
log "health check FAILED ($fails/$THRESHOLD)"

if [ "$fails" -lt "$THRESHOLD" ]; then
  exit 0
fi

log "threshold reached; restarting container"
if docker restart app >/dev/null 2>&1; then
  # Discourse is not ready the moment the container is: unicorn and Postgres
  # take a couple of minutes, during which nginx answers 502. Poll instead of
  # sleeping a fixed interval, or every successful recovery pages a human.
  for _ in $(seq 1 20); do   # up to ~5 minutes
    sleep 15
    if curl -fsS -k -o /dev/null --max-time 20 \
          -H "Host: ${HOSTNAME_CANON}" "https://127.0.0.1/srv/status"; then
      log "restart succeeded"
      echo 0 > "$STATE"
      exit 0
    fi
  done
fi

# Still down after a restart. Log at a level the Ops Agent ships to Cloud
# Logging, so an alert policy can fire; do not reboot in a loop.
log "ERROR: Discourse still down after restart -- needs a human"
echo 0 > "$STATE"
exit 1
