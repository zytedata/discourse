# Discourse community site on a ZADP VM

A deliberately minimal, single-VM Discourse install in the ZADP project
`zyte-vm-community-019d`. This is **separate** from the `zyte-deploy.md` /
`web_only` path at the root of this repo — that one runs Discourse on the Zyte
deploy platform; this is a self-contained box.

- Site: <https://forum.zyte.com>
- ZADP project page (budget, VM card, delete): <https://zadp.zyte.group/vm/8/>

## What exists

| Thing | Value |
|---|---|
| VM | `discourse`, zone `us-east1-b`, `e2-medium` (2 vCPU / 4 GB; was `e2-small` until the CPU-starved rebuild below) |
| Disk | 20 GB `pd-balanced`, daily snapshots kept 14 days (`daily-14d`) |
| Swap | 2 GB on `/swapfile` (Discourse requires swap under 4 GB RAM) |
| OS | newest Ubuntu LTS family, discovered at create time |
| Install | `discourse_docker` standalone at `/var/discourse` |
| Firewall | `allow-web` (tcp 80/443, tag `web`) + ZADP's IAP-only SSH |
| Hostname | `forum.zyte.com` (canonical); `community.zyte.com` and the ZADP name are cert SANs, both 301 to it |
| IP | `34.24.237.156`, **static** (`discourse-ip`) — the zyte.com A record depends on it |
| TLS | Let's Encrypt, obtained and renewed by Discourse's own nginx |
| Mail | Mailgun, `smtp.mailgun.org:587` STARTTLS, from `noreply@mg.zyte.com` |

Not Discourse's documented 1 GB minimum: asset compilation OOMs or crawls at
1 GB on burstable CPU, and `e2-small` ran out of CPU credit mid-rebuild.

## Files here

| File | Purpose |
|---|---|
| `create-vm.sh` | recreates the VM, firewall rule and startup script from nothing |
| `startup-script.sh` | Ops Agent, `unattended-upgrades`, `needrestart`, 2 GB swap |
| `app.yml` | the Discourse container config; goes to `/var/discourse/containers/app.yml` |
| `inject-smtp.sh` | substitutes the real SMTP password into `app.yml` on the VM |

## Secrets

`app.yml` here is tracked in git, so it carries
`DISCOURSE_SMTP_PASSWORD: "__FROM_SECRET_MANAGER__"`. The real value is recorded in
this project's Secret Manager as **`discourse-smtp-password`** and is put in place
on the VM only.

**The ZADP agent service account cannot read secrets back.** `roles/editor` grants
`secretmanager.versions.add` but not `secretmanager.versions.access`, so the agent
can write a new version and never retrieve it. Secret Manager is therefore a record
for a human, not a source the deploy can pull from. Two consequences:

- A human (or any identity with `roles/secretmanager.secretAccessor`) reads it with
  `gcloud secrets versions access latest --secret=discourse-smtp-password`.
- The VM's runtime service account cannot read it either, so there is no boot-time
  fetch. Granting that needs a project IAM change the agent account is not
  permitted to make — ask in #zadp-support.

To deploy a config change, supply the password on **stdin**:

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
gcloud compute scp zadp-vm/app.yml zadp-vm/inject-smtp.sh discourse:/tmp/ \
  --zone=us-east1-b --tunnel-through-iap
# reads the password from your terminal, never from argv
read -rs SMTP_PW && printf '%s\n' "$SMTP_PW" \
| gcloud compute ssh discourse --zone=us-east1-b --tunnel-through-iap --command='
    set -e
    sudo cp /tmp/app.yml /var/discourse/containers/app.yml
    sudo bash /tmp/inject-smtp.sh
    rm -f /tmp/app.yml /tmp/inject-smtp.sh'
unset SMTP_PW
```

Then rebuild (see the detached-unit command below). `inject-smtp.sh` takes the
password on stdin and never as an argument — argv is readable by any local user
through `/proc`.

## Rebuild from nothing

```bash
./zadp-vm/create-vm.sh      # prints the remaining on-VM steps
```

## Day to day

Every `gcloud` call needs this project's own configuration. **Never** activate it
globally — that repoints `gcloud` and `kubectl` machine-wide:

```bash
export CLOUDSDK_ACTIVE_CONFIG_NAME=zadp-zyte-vm-community-019d
```

```bash
gcloud compute ssh discourse --zone=us-east1-b --tunnel-through-iap
cd /var/discourse
sudo ./launcher logs app          # what it's doing
sudo ./launcher restart app       # restart, no rebuild
sudo ./launcher rebuild app       # after editing containers/app.yml (~15-25 min)
```

Long-running work over the tunnel dies when the session drops (`broken pipe`), so
run a bootstrap or rebuild as a detached unit:

```bash
sudo systemd-run --unit=discourse-bootstrap --collect \
  --working-directory=/var/discourse \
  --property=StandardOutput=append:/var/log/discourse-bootstrap.log \
  --property=StandardError=append:/var/log/discourse-bootstrap.log \
  --property=TimeoutStartSec=infinity \
  /var/discourse/launcher rebuild app
```

**Do not stop this VM.** It serves a public community and is expected to be up
all the time. The cost guidance in the ZADP skill about stopping idle VMs is
written for sandboxes and does not apply here. Stopping it is also the one thing
that would break `forum.zyte.com`, if the address were not static.

## Availability

| Failure | Recovers automatically? | Mechanism |
|---|---|---|
| Google host failure, VM crash | yes | `automaticRestart: true` |
| Google host maintenance | yes, no downtime | `onHostMaintenance: MIGRATE` |
| VM reboot | yes | `docker.service` enabled at boot |
| Container exits or is killed | yes | `--restart=always` |
| App up but not serving | yes, within ~15 min | `discourse-healthcheck.timer` |
| Accidental `instances delete` | blocked | deletion protection enabled |
| Boot disk lost, VM deleted on purpose | **no** | restore from backup, see below |

`--restart=always` only reacts to a process *exiting*. A wedged unicorn, Postgres
out of connections, or an OOM that leaves the process alive all look like
"container up, site down", and nothing else notices. `discourse-healthcheck.sh`
probes `/srv/status` over loopback every 5 minutes and restarts the container
after 3 consecutive failures.

Two guards exist because their absence caused a real outage on 2026-09-20: the
first version had no boot grace and no lock, so after a rebuild it restarted the
container every 5 minutes while it was still legitimately booting, and kept the
site down instead of fixing it.

- **Boot grace (10 min).** A container that started recently is *booting*, not
  wedged. Discourse takes 2-5 minutes to serve after a restart or rebuild.
- **Restart cooldown (1 h) and a lock.** One restart, then escalate to an ERROR
  log for a human. It never restarts in a loop, and runs cannot overlap and
  corrupt the counter.

`THRESHOLD`, `BOOT_GRACE` and `RESTART_COOLDOWN` are env-overridable so the
recovery path can be exercised without waiting out the real windows. Verified
against five cases: healthy site (no-op), booting container (left alone),
concurrent runs (lock holds), genuinely stopped container (restarted and
recovered), and a second failure inside the cooldown (escalates instead of
restarting again).

A Cloud Monitoring uptime check hits `https://forum.zyte.com/srv/status`
from the US and Europe every 5 minutes, and the alert policy
*"forum.zyte.com is down"* emails the owner. That is the backstop for when
the watchdog itself cannot fix it.

**What this design cannot do is survive losing the VM.** Postgres is on the local
disk, so recovery from VM loss is a restore, measured in tens of minutes. The
textbook answer — a managed instance group with autohealing — is *wrong here*: a
MIG recreates instances from an image and would destroy the database. Real
self-healing needs the state off the box (Cloud SQL + GCS uploads), which is what
the `web_only` setup at the root of this repo does.

## Staying current

`app.yml` pins `params: version: tests-passed`. The web template's own default is
`latest` — the untested tip of Discourse's main branch, which is the wrong
default for a forum people rely on. `tests-passed` is still current but only
takes commits that passed CI. Use `stable` for release-only updates, or a sha to
freeze.

Note this is the *application* version. It has nothing to do with the
`discourse_docker` copy in this repo's root — the image clones Discourse at build
time. See `zadp-vm/UNFORKING.md`.

| Mechanism | Downtime | Use for |
|---|---|---|
| Admin → `/admin/upgrade` (`docker_manager`) | seconds | routine updates |
| `./launcher rebuild app` | ~20 min | template or env changes |
| `discourse-update.timer` | ~20 min | staying patched unattended |

`discourse-update.timer` runs on the first Sunday of each month at 03:30 UTC.
`discourse-update.sh` backs up first, records the current revision, rebuilds,
then polls until the site actually serves. If it does not come back it logs the
old revision to pin for a rollback and stops — it does not retry a rebuild loop
on a broken site. The uptime alert is what reaches a human.

## Backups

| | |
|---|---|
| Bucket | `gs://zyte-vm-community-019d-discourse-backups` (US multi-region, versioned) |
| Schedule | `discourse-backup.timer`, daily 02:30 UTC |
| Retention | 90 days live, 30 days for noncurrent versions, 3 days on the VM |
| Identity | the VM's runtime SA, granted `roles/storage.objectAdmin` **on this bucket only** |

`discourse-backup-to-gcs.sh` takes a Discourse backup, refuses to upload an
archive that will not list or that contains no `dump.sql`, and refuses to prune
local copies until the upload is confirmed present in the bucket.

Restore, on a VM with Discourse already bootstrapped:

```bash
gcloud storage ls gs://zyte-vm-community-019d-discourse-backups/discourse/
gcloud storage cp gs://.../discourse/<file>.tar.gz \
  /var/discourse/shared/standalone/backups/default/
cd /var/discourse
sudo ./launcher enter app
discourse enable_restore
discourse restore <file>.tar.gz
discourse disable_restore
```

**This has not been restore-tested end to end.** What has been verified is that
the stored archive downloads from the bucket, lists, and yields a valid
PostgreSQL dump. Run a real restore onto a scratch VM before trusting it with
content that matters.

**The bucket is still inside this project.** That protects against losing the VM
or its disk. It does *not* protect against the project itself being the problem —
the budget cap unlinking billing, or the project being deleted. A genuine
off-project copy needs a destination outside `zyte-vm-community-019d`; ask the
owner where.

## Gotchas found the hard way

- GCE blocks outbound tcp:25, so Mailgun's port 25 is not usable here; 587 is.
  Mailgun also rejects From addresses outside a verified sending domain, which is
  why `DISCOURSE_NOTIFICATION_EMAIL` is on `mg.zyte.com` and not on the VM's
  ZADP hostname.
- `DISCOURSE_SMTP_ADDRESS: smtp.example.com` is a **sentinel**: Discourse's web
  template aborts the build on it unless `DISCOURSE_SKIP_EMAIL_SETUP: "1"` is set.
- `pkill -f "launcher bootstrap"` over SSH matches **its own** command line and
  kills the session. Use the bracket trick: `pkill -f "launche[r] bootstrap"`.
  Same for `pgrep -f`, which otherwise always reports the process as running.
- Do not pass `--troubleshoot` to `gcloud compute ssh`; it enables
  `networkmanagement.googleapis.com` on the project without asking.

## Verified on 2026-09-18

- `https://discourse.community.zadp-vms.zyte.group/srv/status` -> 200
- Let's Encrypt certificate issued, `notAfter=Dec 17 15:48:49 2026 GMT`, renewal
  cron (`acme.sh --cron`) present inside the container
- `http://` -> 301 to `https://`, `DISCOURSE_FORCE_HTTPS=true`
- Mailgun login succeeded from the VM over 587/STARTTLS (465/SSL also works)
- Ops Agent and `unattended-upgrades` both active

Memory is tight: 1.4 GB of 1.9 GB in use with ~400 MB of swap touched, 2 unicorn
workers. It runs, but `e2-medium` (4 GB) is the upgrade if it starts swapping
under real traffic.

## Outstanding work

1. **No admin account exists yet.** Sign up at the site with
   `angel.munoz@zyte.com` — it is in `DISCOURSE_DEVELOPER_EMAILS`, so the first
   account registered with it becomes admin. SMTP works, so the activation mail
   will arrive.
2. **Discourse-level backups.** The snapshot schedule protects the *disk*; it is
   not a Discourse backup, and Postgres lives inside this VM, so app and data die
   together. Before real content lands: enable Discourse's scheduled backups and
   push them to a bucket **outside this project**, then restore one to prove it
   works. The ZADP budget's hard cap can unlink billing, after which resources
   here become deletable — an off-project copy is the only thing that survives.
3. **Weekly maintenance report.** `unattended-upgrades` applies patches, but
   nothing yet reports upgradable packages, `pro security-status`, pending
   restarts (`needrestart`) or days-to-expiry on the TLS certificate.

## Cost

Roughly **$19/month** with the VM running continuously: ~$13.50 VM, ~$2 disk,
~$3.65 ephemeral external IP (the IP bills only while the VM runs). Budget is
$50/month with alerts at 50/80% and possible billing unlink at 100%. Stopping the
VM drops it to about $2–6.

## Owner

angel.munoz@zyte.com

## Hostname history

- **2026-09-30**: canonical moved from `community.zyte.com` to `forum.zyte.com`.
  `community.zyte.com` stays a cert SAN and 301 target so existing links,
  bookmarks and already-sent emails keep working. Updated in lockstep: the live
  VM's `app.yml`, this repo's copy, `discourse-update.sh` /
  `discourse-healthcheck.sh`'s canonical Host default, and the Cloud Monitoring
  uptime check + alert (the monitored resource can't be patched in place --
  create-new-delete-old, then repoint the alert policy's condition filter at the
  new check_id).

  **The first rebuild attempt failed** with
  `MiniRacer::ScriptTerminatedError` during asset precompile -- a JS-minifier
  worker hit its 15-second script timeout. `docker stats` showed the container
  at ~98% CPU under plain production traffic, no rebuild running: `e2-small`
  sustains only 50% of one physical core across its "2 vCPUs" and bursts for
  just dozens of seconds beyond that, which a parallel asset build can burn
  through mid-precompile. While the rebuild had the old container stopped, the
  boot-grace-aware watchdog (correctly) restarted it, so `community.zyte.com`
  kept serving throughout on the pre-change image -- `forum.zyte.com` 000'd in
  that window because that container's cert had no SAN for it yet. A plain
  retry succeeded; the `docker commit` step alone then took ~13 minutes
  (heavy disk read I/O, `pd-balanced` throughput-bound, not a hang). If a
  rebuild fails this way again, that is a capacity signal, not a config bug --
  see "Staying current" above on when to move to `e2-medium`. (Since moved to
  `e2-medium`. Since 2026-11-18 the watchdog waits for a rebuild to end before
  restarting anything, so the old container no longer competes with the build.)
- **2026-09-18**: `community.zyte.com` made canonical; the ZADP-assigned name
  (`discourse.community.zadp-vms.zyte.group`) kept as the fallback alias.
