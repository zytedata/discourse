#!/usr/bin/env bash
#
# Monthly unattended Discourse update.
#
# Rationale: a self-hosted forum that drifts is the security risk, not one that
# is a fortnight behind tip. app.yml pins `version: tests-passed`, so a rebuild
# picks up CI-passed commits only.
#
# Order matters: back up FIRST, then rebuild, then verify. If verification
# fails, log at ERROR and stop -- do not retry a rebuild loop on a broken site.
# The Cloud Monitoring uptime alert is what reaches a human.
set -uo pipefail

CANON="${DISCOURSE_HOSTNAME_CANON:-forum.zyte.com}"
log() { logger -t discourse-update -s "$*"; }

log "starting monthly update"

# 1. A backup we could actually roll back to.
if ! systemctl start discourse-backup.service; then
  log "ERROR: pre-update backup failed -- refusing to rebuild"
  exit 1
fi
log "pre-update backup ok"

# 2. Record what we are on, so a rollback has something to pin to.
OLD_SHA=$(docker exec -u discourse app git -C /var/www/discourse rev-parse HEAD 2>/dev/null || echo unknown)
log "current revision: $OLD_SHA"

# 3. Rebuild. This is ~20 minutes of downtime; the timer runs it at a quiet hour.
if ! /var/discourse/launcher rebuild app; then
  log "ERROR: rebuild failed -- site may be down, needs a human. Previous revision was $OLD_SHA"
  exit 1
fi

# 4. Prove it actually serves before calling this a success.
for _ in $(seq 1 20); do
  sleep 15
  if curl -fsS -k -o /dev/null --max-time 20 -H "Host: ${CANON}" "https://127.0.0.1/srv/status"; then
    NEW_SHA=$(docker exec -u discourse app git -C /var/www/discourse rev-parse HEAD 2>/dev/null || echo unknown)
    log "OK: update complete, $OLD_SHA -> $NEW_SHA"
    exit 0
  fi
done

log "ERROR: rebuilt but not serving after 5 minutes. Roll back by setting"
log "ERROR:   params: version: $OLD_SHA   in /var/discourse/containers/app.yml"
log "ERROR: then ./launcher rebuild app. Restore procedure: zadp-vm/README.md"
exit 1
