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
# HARD-WON RULE: a container that has only just started is BOOTING, not wedged.
# Discourse takes 2-5 minutes to serve after a restart or rebuild. An earlier
# version of this script had no boot grace and no lock, so it restarted the
# container mid-boot every 5 minutes and kept the site down instead of fixing
# it. Both guards below exist because of that outage -- do not remove them.
set -uo pipefail

CANON="${DISCOURSE_HOSTNAME_CANON:-community.zyte.com}"
STATE=/var/lib/discourse-healthcheck.fails
LAST_RESTART=/var/lib/discourse-healthcheck.last-restart
LOCK=/var/lock/discourse-healthcheck.lock
# Overridable so the recovery path can be exercised without waiting out the
# real grace window. Defaults are what runs in production.
THRESHOLD="${THRESHOLD:-3}"                  # ~15 minutes of failure before acting
BOOT_GRACE="${BOOT_GRACE:-600}"              # 10 min: longer than a normal Discourse boot
RESTART_COOLDOWN="${RESTART_COOLDOWN:-3600}"

log() { logger -t discourse-health -s "$*"; }

# One at a time. Overlapping runs corrupted the failure counter before.
exec 9>"$LOCK"
flock -n 9 || { log "another check is running; skipping"; exit 0; }

mkdir -p "$(dirname "$STATE")"
now=$(date +%s)

probe() {
  curl -fsS -k -o /dev/null --max-time 20 \
    -H "Host: ${CANON}" "https://127.0.0.1/srv/status"
}

if probe; then
  fails=$(cat "$STATE" 2>/dev/null || echo 0)
  [ "$fails" -gt 0 ] && log "recovered after $fails consecutive failures"
  echo 0 > "$STATE"
  exit 0
fi

# Failing. Is it merely booting?
started=$(docker inspect -f '{{.State.StartedAt}}' app 2>/dev/null || echo "")
if [ -n "$started" ]; then
  age=$(( now - $(date -d "$started" +%s 2>/dev/null || echo "$now") ))
  if [ "$age" -lt "$BOOT_GRACE" ]; then
    log "not serving, but container started ${age}s ago -- still booting, leaving it alone"
    exit 0
  fi
fi

fails=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$STATE"
log "health check FAILED ($fails/$THRESHOLD)"
[ "$fails" -lt "$THRESHOLD" ] && exit 0

# Do not restart repeatedly. If a restart did not fix it, a human is needed.
last=$(cat "$LAST_RESTART" 2>/dev/null || echo 0)
if [ $(( now - last )) -lt "$RESTART_COOLDOWN" ]; then
  log "ERROR: still down $(( (now - last) / 60 ))m after a restart -- needs a human, not another restart"
  exit 1
fi

log "threshold reached; restarting container"
echo "$now" > "$LAST_RESTART"
echo 0 > "$STATE"
# Deliberately no wait-and-verify here: the next run lands inside BOOT_GRACE and
# will leave the container alone, and the run after that reports the truth.
docker restart app >/dev/null 2>&1 || log "ERROR: docker restart app failed"
exit 0
