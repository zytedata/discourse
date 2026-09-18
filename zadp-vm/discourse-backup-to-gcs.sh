#!/usr/bin/env bash
#
# Take a Discourse backup and copy it off the VM into Cloud Storage.
#
# Why this exists: Postgres runs inside the app container on this VM's local
# disk, so the forum and its data die together. Disk snapshots protect against
# disk failure, not against a bad upgrade, an accidental drop, or the project's
# budget cap unlinking billing. This is the copy that survives losing the VM.
#
# Runs as root from discourse-backup.timer. Uploads as the VM's runtime service
# account, which holds roles/storage.objectAdmin on the bucket only.
set -euo pipefail

BUCKET="${DISCOURSE_BACKUP_BUCKET:-zyte-vm-community-019d-discourse-backups}"
BACKUP_DIR=/var/discourse/shared/standalone/backups/default
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-3}"

log() { logger -t discourse-backup -s "$*"; }

command -v gcloud >/dev/null || { log "FATAL: gcloud not installed"; exit 1; }
docker inspect -f '{{.State.Running}}' app 2>/dev/null | grep -q true \
  || { log "FATAL: container 'app' is not running"; exit 1; }

before=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l || true)
log "starting backup (existing local archives: $before)"

# Discourse writes the archive into $BACKUP_DIR on the host via the /shared mount.
docker exec app discourse backup

FILE=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)
[ -n "$FILE" ] || { log "FATAL: no archive found in $BACKUP_DIR"; exit 1; }

# An archive that will not list is not a backup. Fail loudly rather than
# uploading something unrestorable.
#
# Note: the listing is captured first rather than piped into `grep -q`. Under
# `set -o pipefail`, grep -q exits on the first match and closes the pipe, tar
# takes SIGPIPE, and the whole pipeline reports failure on a perfectly good
# archive.
LISTING=$(tar -tzf "$FILE" 2>/dev/null) \
  || { log "FATAL: $FILE is not a readable tar.gz"; exit 1; }
grep -q 'dump.sql' <<<"$LISTING" \
  || { log "FATAL: $FILE contains no database dump"; exit 1; }

SIZE=$(du -h "$FILE" | cut -f1)
log "uploading $(basename "$FILE") ($SIZE) to gs://$BUCKET/discourse/"
gcloud storage cp "$FILE" "gs://$BUCKET/discourse/" --quiet

# Confirm it is actually there before pruning anything locally.
gcloud storage ls "gs://$BUCKET/discourse/$(basename "$FILE")" >/dev/null \
  || { log "FATAL: upload not visible in bucket; keeping all local copies"; exit 1; }

find "$BACKUP_DIR" -name '*.tar.gz' -mtime "+$KEEP_LOCAL_DAYS" -delete
log "OK: $(basename "$FILE") ($SIZE) in gs://$BUCKET/discourse/"
